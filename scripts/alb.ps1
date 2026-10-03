$ErrorActionPreference = "Stop"

$Region = "us-east-1"
$TeamSeed = "7579"
$NamePrefix = "assignment1-team-$TeamSeed"

$AlbName = "$NamePrefix-alb"
$AlbSecurityGroupName = "$NamePrefix-alb-sg"

$Cluster1Name = "$NamePrefix-c1"
$Cluster2Name = "$NamePrefix-c2"

$TargetGroup1Name = "$NamePrefix-c1-tg"
$TargetGroup2Name = "$NamePrefix-c2-tg"

$ListenerPort = 80
$InstancePort = 8000


function Invoke-AwsJson {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    $output = & aws @Arguments --region $Region 2>&1

    $exitCode = $LASTEXITCODE

    $ErrorActionPreference = $oldErrorActionPreference
    if ($exitCode -ne 0) {
        throw ($output -join "`n")
    }

    if ([string]::IsNullOrWhiteSpace(($output -join ""))) {
        return $null
    }

    return ($output -join "`n" | ConvertFrom-Json)
}


function Get-RunningInstances {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ClusterName
    )

    $result = Invoke-AwsJson @(
        "ec2", "describe-instances",
        "--filters",
        "Name=tag:Name,Values=$ClusterName",
        "Name=instance-state-name,Values=running",
        "--output", "json"
    )

    $instances = @()

    foreach ($reservation in $result.Reservations) {
        foreach ($instance in $reservation.Instances) {
            $instances += [PSCustomObject]@{
                Id        = $instance.InstanceId
                VpcId     = $instance.VpcId
                SubnetId  = $instance.SubnetId
                PrivateIp = $instance.PrivateIpAddress
                PublicIp  = $instance.PublicIpAddress
            }
        }
    }

    return $instances
}


function Get-VpcId {
    param(
        [Parameter(Mandatory = $true)]
        $Instances
    )

    if ($Instances.Count -eq 0) {
        throw "Aucune instance running trouvée."
    }

    return $Instances[0].VpcId
}


function Get-AlbSubnets {
    param(
        [Parameter(Mandatory = $true)] $Instances,
        [Parameter(Mandatory = $true)] [string]$VpcId
    )

    $subnetIds = @($Instances | ForEach-Object { $_.SubnetId } | Sort-Object -Unique)

    if ($subnetIds.Count -ge 2) {
        return $subnetIds
    }

    $result = Invoke-AwsJson @(
        "ec2", "describe-subnets",
        "--filters", "Name=vpc-id,Values=$VpcId", "Name=default-for-az,Values=true",
        "--output", "json"
    )
    $extra = $result.Subnets | Where-Object { $_.SubnetId -notin $subnetIds } | Select-Object -First 1

    if ($null -eq $extra) {
        throw "Impossible de trouver un deuxième subnet pour l'ALB."
    }

    return $subnetIds + $extra.SubnetId
}


function Get-OrCreate-AlbSecurityGroup {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VpcId
    )

    $result = Invoke-AwsJson @(
        "ec2", "describe-security-groups",
        "--filters",
        "Name=group-name,Values=$AlbSecurityGroupName",
        "Name=vpc-id,Values=$VpcId",
        "--output", "json"
    )

    if ($result.SecurityGroups.Count -gt 0) {
        $sgId = $result.SecurityGroups[0].GroupId
        Write-Host "[REUSE] ALB Security Group: $sgId"
        return $sgId
    }

    $create = Invoke-AwsJson @(
        "ec2", "create-security-group",
        "--group-name", $AlbSecurityGroupName,
        "--description", "ALB security group for team $TeamSeed",
        "--vpc-id", $VpcId,
        "--tag-specifications",
        "ResourceType=security-group,Tags=[{Key=Name,Value=$AlbSecurityGroupName}]",
        "--output", "json"
    )

    $sgId = $create.GroupId

    Write-Host "[CREATE] ALB Security Group: $sgId"

    try {
        & aws ec2 authorize-security-group-ingress `
            --region $Region `
            --group-id $sgId `
            --protocol tcp `
            --port 80 `
            --cidr 0.0.0.0/0 2>&1 | Out-Null

        if ($LASTEXITCODE -ne 0) {
            Write-Host "[INFO] La règle HTTP 80 existe peut-être déjà."
        }
    }
    catch {
        Write-Host "[INFO] Impossible d'ajouter la règle HTTP 80."
    }

    return $sgId
}

function Get-OrCreate-TargetGroup {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$VpcId
    )

    Write-Host "Checking Target Group: $Name"

    # Target Group lookup
    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    $existing = aws elbv2 describe-target-groups `
        --region $Region `
        --names $Name `
        --output json 2>$null

    $exitCode = $LASTEXITCODE

    $ErrorActionPreference = $oldErrorActionPreference

    # Target Group exists
    if ($exitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace(($existing -join ""))) {

        $json = ($existing -join "`n") | ConvertFrom-Json

        if ($json.TargetGroups.Count -gt 0) {
            $arn = $json.TargetGroups[0].TargetGroupArn

            Write-Host "[REUSE] Target Group: $Name"

            return $arn
        }
    }

    # Target Group does not exist → create it
    Write-Host "[CREATE] Target Group: $Name"

    $result = Invoke-AwsJson @(
        "elbv2", "create-target-group",
        "--name", $Name,
        "--protocol", "HTTP",
        "--port", "$InstancePort",
        "--vpc-id", $VpcId,
        "--target-type", "instance",
        "--health-check-protocol", "HTTP",
        "--health-check-port", "$InstancePort",
        "--health-check-path", "/health",
        "--health-check-interval-seconds", "10",
        "--health-check-timeout-seconds", "5",
        "--healthy-threshold-count", "2",
        "--unhealthy-threshold-count", "2",
        "--matcher", "HttpCode=200",
        "--output", "json"
    )

    $arn = $result.TargetGroups[0].TargetGroupArn

    return $arn
}
function Register-Targets {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetGroupArn,

        [Parameter(Mandatory = $true)]
        $Instances
    )

    if ($Instances.Count -eq 0) {
        throw "Aucune instance à enregistrer dans $TargetGroupArn."
    }

    $targets = @()

    foreach ($instance in $Instances) {
        $targets += "Id=$($instance.Id),Port=$InstancePort"
    }

    $awsArgs = @(
        "elbv2", "register-targets",
        "--target-group-arn", $TargetGroupArn,
        "--targets"
    ) + $targets

    & aws @awsArgs --region $Region 2>&1 | Out-Null

    if ($LASTEXITCODE -ne 0) {
        throw "Impossible d'enregistrer les targets dans $TargetGroupArn."
    }

    Write-Host "[REGISTER] $($Instances.Count) instance(s) -> Target Group"
}


function Get-OrCreate-Alb {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VpcId,

        [Parameter(Mandatory = $true)]
        [string[]]$Subnets,

        [Parameter(Mandatory = $true)]
        [string]$SecurityGroupId
    )

    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    $existing = & aws elbv2 describe-load-balancers `
        --region $Region `
        --names $AlbName `
        --output json 2>&1

    $exitCode = $LASTEXITCODE

    $ErrorActionPreference = $oldErrorActionPreference

    if ($exitCode -eq 0) {

        $jsonText = ($existing -join "`n").Trim()

        if (-not [string]::IsNullOrWhiteSpace($jsonText)) {

            $json = $jsonText | ConvertFrom-Json

            if ($json.LoadBalancers.Count -gt 0) {
                Write-Host "[REUSE] ALB: $AlbName" -ForegroundColor Green

                & aws elbv2 set-subnets --region $Region `
                    --load-balancer-arn $json.LoadBalancers[0].LoadBalancerArn `
                    --subnets $Subnets 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "Impossible de mettre à jour les subnets de l'ALB." }

                return $json.LoadBalancers[0]
            }
        }
    }

    $awsArgs = @(
        "elbv2", "create-load-balancer",
        "--name", $AlbName,
        "--security-groups", $SecurityGroupId,
        "--scheme", "internet-facing",
        "--type", "application",
        "--ip-address-type", "ipv4",
        "--subnets"
    ) + $Subnets + @(
        "--tags",
        "Key=Name,Value=$AlbName",
        "Key=TeamSeed,Value=$TeamSeed",
        "--output", "json"
    )

    $result = Invoke-AwsJson $awsArgs
    $alb = $result.LoadBalancers[0]

    Write-Host "[CREATE] ALB: $AlbName"

    & aws elbv2 wait load-balancer-available `
        --region $Region `
        --load-balancer-arns $alb.LoadBalancerArn

    if ($LASTEXITCODE -ne 0) {
        throw "L'ALB n'est pas devenu disponible."
    }

    return $alb
}


function Get-OrCreate-Listener {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AlbArn
    )

    $result = Invoke-AwsJson @(
        "elbv2", "describe-listeners",
        "--load-balancer-arn", $AlbArn,
        "--output", "json"
    )

    foreach ($listener in $result.Listeners) {
        if ($listener.Port -eq $ListenerPort) {
            Write-Host "[REUSE] Listener port $ListenerPort"
            return $listener.ListenerArn
        }
    }

    $result = Invoke-AwsJson @(
        "elbv2", "create-listener",
        "--load-balancer-arn", $AlbArn,
        "--protocol", "HTTP",
        "--port", "$ListenerPort",
        "--default-actions",
        "Type=fixed-response,FixedResponseConfig={StatusCode=404,ContentType=text/plain,MessageBody=RouteNotFound}",
        "--output", "json"
    )

    $listenerArn = $result.Listeners[0].ListenerArn

    Write-Host "[CREATE] Listener port $ListenerPort"

    return $listenerArn
}


function Ensure-Rule {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ListenerArn,

        [Parameter(Mandatory = $true)]
        [int]$Priority,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$TargetGroupArn
    )

    $result = Invoke-AwsJson @(
        "elbv2", "describe-rules",
        "--listener-arn", $ListenerArn,
        "--output", "json"
    )

    foreach ($rule in $result.Rules) {
        if ($rule.Priority -eq "$Priority") {
            & aws elbv2 modify-rule `
                --region $Region `
                --rule-arn $rule.RuleArn `
                --conditions "Field=path-pattern,PathPatternConfig={Values=[$Path]}" `
                --actions "Type=forward,TargetGroupArn=$TargetGroupArn" `
                2>&1 | Out-Null

            if ($LASTEXITCODE -ne 0) {
                throw "Impossible de modifier la règle $Priority."
            }

            Write-Host "[UPDATE] $Path -> Target Group"
            return
        }
    }

    & aws elbv2 create-rule `
        --region $Region `
        --listener-arn $ListenerArn `
        --priority $Priority `
        --conditions "Field=path-pattern,PathPatternConfig={Values=[$Path]}" `
        --actions "Type=forward,TargetGroupArn=$TargetGroupArn" `
        --output json 2>&1 | Out-Null

    if ($LASTEXITCODE -ne 0) {
        throw "Impossible de créer la règle $Priority."
    }

    Write-Host "[CREATE] $Path -> Target Group"
}


function Wait-ForHealthyTargets {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetGroupArn,

        [Parameter(Mandatory = $true)]
        [int]$ExpectedCount
    )

    Write-Host "Waiting for $ExpectedCount healthy target(s)..."

    for ($attempt = 1; $attempt -le 30; $attempt++) {

        $result = Invoke-AwsJson @(
            "elbv2", "describe-target-health",
            "--target-group-arn", $TargetGroupArn,
            "--output", "json"
        )

        $healthy = @(
            $result.TargetHealthDescriptions |
            Where-Object {
                $_.TargetHealth.State -eq "healthy"
            }
        ).Count

        Write-Host "  $healthy/$ExpectedCount healthy"

        if ($healthy -ge $ExpectedCount) {
            Write-Host "[OK] All targets healthy"
            return
        }

        Start-Sleep -Seconds 5
    }

    throw "Le Target Group n'a pas atteint $ExpectedCount targets healthy."
}


function Main {
    Write-Host "=========================================="
    Write-Host " AWS APPLICATION LOAD BALANCER"
    Write-Host " Team seed: $TeamSeed"
    Write-Host "=========================================="

    # 1. Récupérer les instances existantes
    $cluster1 = @(Get-RunningInstances $Cluster1Name)
    $cluster2 = @(Get-RunningInstances $Cluster2Name)

    if ($cluster1.Count -ne 5) {
        throw "Cluster 1: attendu 5 instances running, trouvé $($cluster1.Count)."
    }

    if ($cluster2.Count -ne 4) {
        throw "Cluster 2: attendu 4 instances running, trouvé $($cluster2.Count)."
    }

    Write-Host "[OK] Cluster 1: $($cluster1.Count) instances"
    Write-Host "[OK] Cluster 2: $($cluster2.Count) instances"

    # 2. VPC + subnets
    $vpcId = Get-VpcId $cluster1
    $allInstances = @($cluster1) + @($cluster2)
    $subnets = @(Get-AlbSubnets $allInstances $vpcId)

    Write-Host "[OK] VPC: $vpcId"
    Write-Host "[OK] Subnets: $($subnets -join ', ')"

    # 3. Security Group de l'ALB
    $albSgId = Get-OrCreate-AlbSecurityGroup $vpcId

    # 4. Target Groups
    $tg1Arn = Get-OrCreate-TargetGroup $TargetGroup1Name $vpcId
    $tg2Arn = Get-OrCreate-TargetGroup $TargetGroup2Name $vpcId

    # 5. Attacher les EC2 aux Target Groups
    Register-Targets $tg1Arn $cluster1
    Register-Targets $tg2Arn $cluster2

    # 6. Créer/réutiliser l'ALB
    $alb = Get-OrCreate-Alb $vpcId $subnets $albSgId
    $albArn = $alb.LoadBalancerArn

    # 7. Listener HTTP :80
    $listenerArn = Get-OrCreate-Listener $albArn

    # 8. Routing par chemin
    Ensure-Rule $listenerArn 10 "/cluster1*" $tg1Arn
    Ensure-Rule $listenerArn 20 "/cluster2*" $tg2Arn

    # 9. Attendre les health checks
    Wait-ForHealthyTargets $tg1Arn 5
    Wait-ForHealthyTargets $tg2Arn 4

    # 10. URL
    $url = "http://$($alb.DNSName)"

    Write-Host ""
    Write-Host "=========================================="
    Write-Host " ALB READY"
    Write-Host "=========================================="
    Write-Host "ALB URL: $url"
    Write-Host "Cluster 1: $url/cluster1"
    Write-Host "Cluster 2: $url/cluster2"
    Write-Host "=========================================="

    # Une seule ligne finale exploitable par assignment1-team.ps1
    Write-Output $url
}


if ($args -contains "--resolve") {
    $result = & aws elbv2 describe-load-balancers `
        --region $Region `
        --names $AlbName `
        --output json 2>$null

    if ($LASTEXITCODE -ne 0) {
        throw "ALB does not exist yet."
    }

    $json = ($result -join "`n") | ConvertFrom-Json
    Write-Output "http://$($json.LoadBalancers[0].DNSName)"
}
else {
    Main
}
