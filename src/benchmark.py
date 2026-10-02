import asyncio
import sys
import aiohttp
import time


async def call_endpoint_http(session, request_num, url):
    headers = {"content-type": "application/json"}

    try:
        async with session.get(url, headers=headers) as response:
            status_code = response.status
            response_json = await response.json()

            print(f"Request {request_num} : Status Code: {status_code}")

            return status_code, response_json

    except Exception as e:
        print(f"Request {request_num} : Failed - {str(e)}")
        return None, str(e)


async def main():
    num_requests = 1000

    url = sys.argv[1]
    start_time = time.time()

    async with aiohttp.ClientSession() as session:
        tasks = [
            call_endpoint_http(session, i, url)
            for i in range(num_requests)
        ]

        await asyncio.gather(*tasks)

    end_time = time.time()

    print(f"\nTotal time taken: {end_time - start_time:.2f} seconds")
    print(
        f"Average time per request: "
        f"{(end_time - start_time) / num_requests:.4f} seconds"
    )


if __name__ == "__main__":
    asyncio.run(main())