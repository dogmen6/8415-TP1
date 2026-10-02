from fastapi import FastAPI, Response
import os

app = FastAPI()

TEAM_SEED = os.getenv("TEAM_SEED", "7579")
INSTANCE_NUMBER = os.getenv("INSTANCE_NUMBER", "unknown")
CLUSTER = os.getenv("CLUSTER", "unknown")


@app.get("/cluster1")
def cluster1(response: Response):
    response.headers["X-Team-Seed"] = TEAM_SEED

    return {
        "message": f"Instance number {INSTANCE_NUMBER} is responding now!",
        "team_seed": int(TEAM_SEED)
    }


@app.get("/cluster2")
def cluster2(response: Response):
    response.headers["X-Team-Seed"] = TEAM_SEED

    return {
        "message": f"Instance number {INSTANCE_NUMBER} is responding now!",
        "team_seed": int(TEAM_SEED)
    }


@app.get("/health")
def health():
    return {
        "status": "healthy",
        "instance_number": INSTANCE_NUMBER,
        "team_seed": int(TEAM_SEED)
    }