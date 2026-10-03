"""Benchmark: send 1000 concurrent GET requests to one URL and save the results.

Usage: python benchmark.py <url> <output.json>
"""
import asyncio
import json
import statistics
import sys
import time
from collections import Counter
from datetime import datetime, timezone

import aiohttp


async def call_endpoint_http(session, request_num, url):
    """Send one GET request and return its status, latency and answering instance."""
    start = time.perf_counter()
    try:
        async with session.get(url) as response:
            data = await response.json()
            return {
                "request": request_num,
                "status": response.status,
                "latency": time.perf_counter() - start,
                "message": data.get("message"),
            }
    except Exception as e:
        return {
            "request": request_num,
            "status": None,
            "latency": time.perf_counter() - start,
            "error": str(e),
        }

def print_summary(results):
    """Print a short summary instead of one line per request."""
    # Keep only successful requests -- failures would distort the latency stats
    successes = [r for r in results if r["status"] == 200]
    failures = len(results) - len(successes)
    latencies = [r["latency"] for r in successes]

    # Number of requests answered by each instance (proves routing / redirection)
    per_instance = Counter(r["message"] for r in successes)

    print(f"Successes: {len(successes)} / Failures: {failures}")

    # Guard: no stats can be computed if every request failed
    if latencies:
        avg = statistics.mean(latencies)
        median = statistics.median(latencies)
        p95 = statistics.quantiles(latencies, n=100)[94]  # 95th percentile
        print(f"Latency (s): avg={avg:.3f}  median={median:.3f}  p95={p95:.3f}")

    print("Requests per instance:")
    for message, count in sorted(per_instance.items()):
        print(f"  {message} -> {count}")

async def main():
    num_requests = 1000

    url = sys.argv[1]
    output_path = sys.argv[2]

    # limit=0 removes aiohttp's default cap of 100 concurrent connections,
    # so the 1000 requests are really sent at the same time.
    connector = aiohttp.TCPConnector(limit=0)

    # UTC timestamps of the run, needed later to query CloudWatch
    start_iso = datetime.now(timezone.utc).isoformat()
    start_time = time.perf_counter()

    async with aiohttp.ClientSession(connector=connector) as session:
        tasks = [
            call_endpoint_http(session, i, url)
            for i in range(num_requests)
        ]

        results = await asyncio.gather(*tasks)

    total_time = time.perf_counter() - start_time
    end_iso = datetime.now(timezone.utc).isoformat()

    print(f"URL: {url}")
    print(f"Total time for {num_requests} concurrent requests: {total_time:.2f} s")
    print_summary(results)

    with open(output_path, "w") as f:
        json.dump(
            {
                "url": url,
                "start": start_iso,
                "end": end_iso,
                "total_time": total_time,
                "results": results,
            },
            f,
            indent=2,
        )
    print(f"Results saved to {output_path}")


if __name__ == "__main__":
    asyncio.run(main())