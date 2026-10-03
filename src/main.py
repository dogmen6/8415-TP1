from fastapi import FastAPI, Response, HTTPException
import os

app = FastAPI()

# Values injected by the systemd service on each EC2 instance
TEAM_SEED = os.getenv("TEAM_SEED", "7579")
INSTANCE_NUMBER = os.getenv("INSTANCE_NUMBER", "unknown")
CLUSTER = os.getenv("CLUSTER", "unknown")


def build_response(response: Response, route_cluster: str):
    """Answer only if this instance belongs to the cluster of the requested route.

    Cluster 1 (t3.micro) must only answer /cluster1 and cluster 2 (m7g.large)
    must only answer /cluster2, as required by the lab (Section 6.2).
    """
    if CLUSTER != route_cluster:
        raise HTTPException(
            status_code=404,
            detail=f"Instance {INSTANCE_NUMBER} is not in cluster {route_cluster}",
        )

    response.headers["X-Team-Seed"] = TEAM_SEED
    return {
        "message": f"Instance number {INSTANCE_NUMBER} is responding now!",
        "team_seed": int(TEAM_SEED),
    }


@app.get("/cluster1")
def cluster1(response: Response):
    return build_response(response, "1")


@app.get("/cluster2")
def cluster2(response: Response):
    return build_response(response, "2")


@app.get("/health")
def health():
    # Used by the ALB target groups and by the custom load balancer probes
    return {
        "status": "healthy",
        "instance_number": INSTANCE_NUMBER,
        "cluster": CLUSTER,
        "team_seed": int(TEAM_SEED),
    }
    
# To test in Powershell use:
# $env:CLUSTER="1"; $env:INSTANCE_NUMBER="1"; uvicorn main:app --port 8001

