param(
    [ValidateSet("none", "alb", "custom")]
    [string]$LoadBalancer = "none",

    [ValidateSet("none", "alb", "custom")]
    [string]$Benchmark = "none"
)

$ErrorActionPreference = "Stop"

$Region = "us-east-1"
$TeamSeed = "7579"
$NamePrefix = "assignment1-team-$TeamSeed"
$SecurityGroupName = "$NamePrefix-sg"
$KeyName = "$NamePrefix-key"

$Cluster1Name = "$NamePrefix-c1"
$Cluster2Name = "$NamePrefix-c2"

$KeyPath = Join-Path $PSScriptRoot "$KeyName.pem"
$MainPyPath = Join-Path $PSScriptRoot "src\main.py"
$BenchmarkScript = Join-Path $PSScriptRoot "src\benchmark.py"
$AlbScript = Join-Path $PSScriptRoot "scripts\alb.ps1"
$CustomScript = Join-Path $PSScriptRoot "scripts\custom_lb.ps1"


function Write-Section($Message) {
    Write-Host ""
    Write-Host "===== $Message =====" -ForegroundColor Cyan
}

function Get-Instances($Name) {

    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    $json = & aws ec2 describe-instances `
        --filters `
            "Name=tag:Name,Values=$Name" `
            "Name=instance-state-name,Values=pending,running,stopping,stopped" `
        --region $Region `
        --query "Reservations[].Instances[].{Id:InstanceId,State:State.Name,IP:PublicIpAddress,PrivateIP:PrivateIpAddress}" `
        --output json 2>&1

    $exitCode = $LASTEXITCODE

    $ErrorActionPreference = $oldErrorActionPreference

    if ($exitCode -ne 0) {
        throw ($json -join "`n")
    }

    $jsonText = ($json -join "`n").Trim()

    if ([string]::IsNullOrWhiteSpace($jsonText) -or $jsonText -eq "[]") {
        return @()
    }

    $objects = $jsonText | ConvertFrom-Json

    if ($null -eq $objects) {
        return @()
    }

    return @($objects | Sort-Object -Property Id)
}


function Wait-ForRunningInstances($Name, $ExpectedCount) {

    $MaxAttempts = 60
    $DelaySeconds = 5

    Write-Host "Waiting for $ExpectedCount instances of $Name to become running..."

    for ($Attempt = 1; $Attempt -le $MaxAttempts; $Attempt++) {

        $Instances = Get-Instances $Name

        $Running = @(
            $Instances | Where-Object {
                $_.State -eq "running"
            }
        ).Count

        Write-Host "  Attempt $Attempt/$MaxAttempts : $Running/$ExpectedCount running"

        if ($Running -ge $ExpectedCount) {
            Write-Host "  OK - $Name has $Running running instances."
            return
        }

        Start-Sleep -Seconds $DelaySeconds
    }

    throw "Timeout: $Name did not reach $ExpectedCount running instances after $($MaxAttempts * $DelaySeconds) seconds."
}

function Ensure-SecurityGroup {
    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    $groupId = aws ec2 describe-security-groups `
        --group-names $SecurityGroupName `
        --region $Region `
        --query "SecurityGroups[0].GroupId" `
        --output text 2>$null

    $exitCode = $LASTEXITCODE

    $ErrorActionPreference = $oldErrorActionPreference

    if ($exitCode -ne 0 -or [string]::IsNullOrWhiteSpace($groupId) -or $groupId -eq "None") {

        $groupId = (aws ec2 create-security-group `
            --group-name $SecurityGroupName `
            --description "LOG8415E TP1 Team $TeamSeed" `
            --region $Region `
            --query "GroupId" `
            --output text).Trim()

        Write-Host "[CREATE] Security Group $groupId"

        aws ec2 authorize-security-group-ingress `
            --group-id $groupId `
            --protocol tcp `
            --port 22 `
            --cidr 0.0.0.0/0 `
            --region $Region | Out-Null

        aws ec2 authorize-security-group-ingress `
            --group-id $groupId `
            --protocol tcp `
            --port 8000 `
            --cidr 0.0.0.0/0 `
            --region $Region | Out-Null
    }
    else {
        Write-Host "[REUSE] Security Group $groupId"
    }

    return $groupId
}

function Ensure-KeyPair {
    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    $exists = aws ec2 describe-key-pairs `
        --key-names $KeyName `
        --region $Region `
        --query "KeyPairs[0].KeyName" `
        --output text 2>$null

    $exitCode = $LASTEXITCODE

    $ErrorActionPreference = $oldErrorActionPreference

    if ($exitCode -ne 0 -or [string]::IsNullOrWhiteSpace($exists) -or $exists -eq "None") {

        Write-Host "[CREATE] Key pair $KeyName"

        aws ec2 create-key-pair `
            --key-name $KeyName `
            --query "KeyMaterial" `
            --output text `
            --region $Region |
            Out-File -Encoding ascii $KeyPath

    }
    else {

        Write-Host "[REUSE] Key pair $KeyName"

        if (-not (Test-Path $KeyPath)) {
            throw "La Key Pair AWS existe, mais le fichier PEM est absent: $KeyPath"
        }
    }

    return $KeyName
}

function Ensure-Instances {

    Write-Section "Ensuring EC2 instances"

    # Récupérer les AMI Amazon Linux 2023
    $X86Ami = & aws ssm get-parameter `
        --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" `
        --query "Parameter.Value" `
        --output text `
        --region $Region

    $ArmAmi = & aws ssm get-parameter `
        --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64" `
        --query "Parameter.Value" `
        --output text `
        --region $Region

    Write-Host "x86 AMI: $X86Ami"
    Write-Host "ARM AMI: $ArmAmi"

    # Security Group + Key Pair
    $SecurityGroupId = Ensure-SecurityGroup
    $null = Ensure-KeyPair

    # ============================================================
    # CLUSTER 1 - 5 x t3.micro
    # ============================================================

    Write-Host ""
    Write-Host "Checking Cluster 1..."

    $Cluster1Instances = Get-Instances $Cluster1Name

    # Garder uniquement running/stopped
    # Count pending instances too to avoid duplicates
    $UsableCluster1 = @(
        $Cluster1Instances | Where-Object {
            $_.State -in "pending", "running", "stopped"
        }
    )

    # Démarrer les instances stopped
    foreach ($Instance in $UsableCluster1) {

        if ($Instance.State -eq "stopped") {

            Write-Host "Starting stopped instance $($Instance.Id)..."

            aws ec2 start-instances `
                --instance-ids $Instance.Id `
                --region $Region | Out-Null
        }
    }

    # Combien faut-il encore créer ?
    $MissingCluster1 = 5 - $UsableCluster1.Count

    Write-Host "Cluster 1: $($UsableCluster1.Count)/5 usable instances"

    if ($MissingCluster1 -gt 0) {

        Write-Host "Creating $MissingCluster1 missing Cluster 1 instance(s)..."

        for ($i = 1; $i -le $MissingCluster1; $i++) {

            aws ec2 run-instances `
                --image-id $X86Ami `
                --instance-type "t3.micro" `
                --count 1 `
                --key-name $KeyName `
                --security-group-ids $SecurityGroupId `
                --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$Cluster1Name}]" `
                --region $Region | Out-Null
        }
    }

    # ============================================================
    # CLUSTER 2 - 4 x m7g.large
    # ============================================================

    Write-Host ""
    Write-Host "Checking Cluster 2..."

    $Cluster2Instances = Get-Instances $Cluster2Name

    # Same as cluster 1: pending instances count as usable
    $UsableCluster2 = @(
        $Cluster2Instances | Where-Object {
            $_.State -in "pending", "running", "stopped"
        }
    )

    # Démarrer les instances stopped
    foreach ($Instance in $UsableCluster2) {

        if ($Instance.State -eq "stopped") {

            Write-Host "Starting stopped instance $($Instance.Id)..."

            aws ec2 start-instances `
                --instance-ids $Instance.Id `
                --region $Region | Out-Null
        }
    }

    # Combien faut-il encore créer ?
    $MissingCluster2 = 4 - $UsableCluster2.Count

    Write-Host "Cluster 2: $($UsableCluster2.Count)/4 usable instances"

    if ($MissingCluster2 -gt 0) {

        Write-Host "Creating $MissingCluster2 missing Cluster 2 instance(s)..."

        for ($i = 1; $i -le $MissingCluster2; $i++) {

            aws ec2 run-instances `
                --image-id $ArmAmi `
                --instance-type "m7g.large" `
                --count 1 `
                --key-name $KeyName `
                --security-group-ids $SecurityGroupId `
                --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$Cluster2Name}]" `
                --region $Region | Out-Null
        }
    }

    # ============================================================
    # ATTENDRE QUE LES 9 INSTANCES SOIENT RUNNING
    # ============================================================

   Write-Host ""
    Write-Host "Waiting for Cluster 1..."
    $null = Wait-ForRunningInstances $Cluster1Name 5

    Write-Host ""
    Write-Host "Waiting for Cluster 2..."
    $null = Wait-ForRunningInstances $Cluster2Name 4

    $FinalCluster1 = Get-Instances $Cluster1Name
    $FinalCluster2 = Get-Instances $Cluster2Name

    $AllInstances = @()

    $AllInstances += @($FinalCluster1)
    $AllInstances += @($FinalCluster2)

    # wait for the EC2 status checks to pass:
    # before Ensure-FastAPI connects to the instances.
    Write-Host ""
    Write-Host "Waiting for instance status checks (can take 2-3 minutes)..."
    $ids = @($AllInstances | ForEach-Object { $_.Id })
    aws ec2 wait instance-status-ok --instance-ids $ids --region $Region
    if ($LASTEXITCODE -ne 0) {
        throw "Instances did not pass status checks."
    }
    Write-Host "[OK] All instances passed status checks" -ForegroundColor Green
    
    return $AllInstances
}

function Ensure-FastAPI($Instances) {
    Write-Section "FASTAPI DEPLOYMENT"

    if (-not (Test-Path $MainPyPath)) {
        throw "Missing $MainPyPath"
    }

    $instanceNumber = 1

    foreach ($instance in $Instances) {
        $id = $instance.Id
        $ip = $instance.IP

        Write-Host "[$instanceNumber/9] Checking $id ($ip)..."
        
        # Update the OS, install Python and the app dependencies in a venv.
        # "&&" stops at the first failing command, so a failure is not silently ignored.
        ssh -o StrictHostKeyChecking=no -i $KeyPath "ec2-user@$ip" `
            "sudo dnf update -y && sudo dnf install -y python3 python3-pip && (test -d /home/ec2-user/venv || python3 -m venv /home/ec2-user/venv) && /home/ec2-user/venv/bin/pip install fastapi 'uvicorn[standard]'" `
            | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Package installation failed on $id." }

        scp -o StrictHostKeyChecking=no -i $KeyPath `
            $MainPyPath "ec2-user@${ip}:/home/ec2-user/main.py" `
            | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Failed to copy main.py to $id." }

        # Instances 1-5 belong to cluster 1 (t3.micro), 6-9 to cluster 2 (m7g.large),
        # because Ensure-Instances returns cluster 1 first.
        $cluster = if ($instanceNumber -le 5) { "1" } else { "2" }
        $serviceContent = @"
[Unit]
Description=LOG8415E FastAPI Application
After=network.target

[Service]
User=ec2-user
WorkingDirectory=/home/ec2-user
Environment="TEAM_SEED=$TeamSeed"
Environment="INSTANCE_NUMBER=$instanceNumber"
Environment="CLUSTER=$cluster"
ExecStart=/home/ec2-user/venv/bin/uvicorn main:app --host 0.0.0.0 --port 8000
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
"@

        $tempService = Join-Path $PSScriptRoot "fastapi-$instanceNumber.service"
        Set-Content -Path $tempService -Value $serviceContent -Encoding ASCII

        scp -o StrictHostKeyChecking=no -i $KeyPath `
            $tempService "ec2-user@${ip}:/tmp/fastapi.service" `
            | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Failed to copy the systemd service to $id." }

        ssh -o StrictHostKeyChecking=no -i $KeyPath "ec2-user@$ip" `
            "sudo mv /tmp/fastapi.service /etc/systemd/system/fastapi.service; sudo systemctl daemon-reload; sudo systemctl enable fastapi; sudo systemctl restart fastapi" `
            | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Failed to start the FastAPI service on $id." }

        $status = ssh -o StrictHostKeyChecking=no -i $KeyPath `
            "ec2-user@$ip" "systemctl is-active fastapi" 2>$null

        Remove-Item $tempService -Force -ErrorAction SilentlyContinue

        if ($status.Trim() -ne "active") {
            throw "FastAPI failed to start on $($instance.Id)."
        }

        Write-Host "      [OK] FastAPI active" -ForegroundColor Green
        $instanceNumber++
    }
}

function Start-CustomLoadBalancer {
    Write-Section "CUSTOM LOAD BALANCER"

    if (-not (Test-Path $CustomScript)) {
        throw "Missing $CustomScript"
    }

    $portInUse = Get-NetTCPConnection -LocalPort 8080 -State Listen -ErrorAction SilentlyContinue

    if ($null -ne $portInUse) {
        Write-Host "[REUSE] Custom LB already listening on http://127.0.0.1:8080"
        return
    }

    Write-Host "[START] Custom LB on http://127.0.0.1:8080"

    Start-Process `
        -FilePath "powershell.exe" `
        -ArgumentList @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $CustomScript,
            "--serve"
        ) `
        -WorkingDirectory $PSScriptRoot `
        -WindowStyle Hidden

    for ($i = 1; $i -le 30; $i++) {
        Start-Sleep -Seconds 1

        $listening = Get-NetTCPConnection -LocalPort 8080 -State Listen -ErrorAction SilentlyContinue
        if ($null -ne $listening) {
            Write-Host "[OK] Custom LB is running" -ForegroundColor Green
            return
        }
    }

    throw "Custom LB did not start on port 8080."
}

function Get-AlbUrl {
    $url = (& $AlbScript --resolve).Trim()

    if ([string]::IsNullOrWhiteSpace($url)) {
        throw "Could not resolve the existing AWS ALB."
    }

    return $url
}

function Get-CustomUrl {
    $url = (& $CustomScript --resolve).Trim()

    if ([string]::IsNullOrWhiteSpace($url)) {
        throw "Could not resolve the Custom LB."
    }
    return $url
}

function Run-Benchmark($BaseUrl, $Label) {
    Write-Host ""
    Write-Host "----- $Label /cluster1 -----" -ForegroundColor Yellow
    python $BenchmarkScript "$BaseUrl/cluster1"

    Write-Host ""
    Write-Host "----- $Label /cluster2 -----" -ForegroundColor Yellow
    python $BenchmarkScript "$BaseUrl/cluster2"
}

# ============================================================
# MAIN
# ============================================================

if ($LoadBalancer -eq "none" -and $Benchmark -eq "none") {
    $instances = @(Ensure-Instances)
    Ensure-FastAPI $instances

    Write-Host ""
    Write-Host "Infrastructure and FastAPI are ready." -ForegroundColor Green
    exit 0
}

if ($LoadBalancer -ne "none") {
    $instances = @(Ensure-Instances)
    Ensure-FastAPI $instances

    if ($LoadBalancer -eq "alb") {
        Write-Section "AWS APPLICATION LOAD BALANCER"
        
        $albUrl = (& $AlbScript).Trim()
 
        if ([string]::IsNullOrWhiteSpace($albUrl)) {
            throw "AWS ALB script did not return a URL."
        }

        Write-Host "AWS ALB: $albUrl" -ForegroundColor Green
    }
    elseif ($LoadBalancer -eq "custom") {
        Start-CustomLoadBalancer
        Write-Host "Custom LB: http://127.0.0.1:8080" -ForegroundColor Green
    }
}

if ($Benchmark -ne "none") {
    if ($Benchmark -eq "alb") {
        $albUrl = Get-AlbUrl
        Run-Benchmark $albUrl "AWS ALB"
    }
    elseif ($Benchmark -eq "custom") {
        Start-CustomLoadBalancer
        $customUrl = Get-CustomUrl
        Run-Benchmark $customUrl "Custom LB"
    }
}

Write-Host ""
Write-Host "===== DONE =====" -ForegroundColor Green
