FROM python:3.11-slim-bookworm
RUN pip install --no-cache-dir aiohttp==3.11.12
WORKDIR /scripts
# distill_collector.py is mounted from ConfigMap at runtime
CMD ["python", "/scripts/distill_collector.py"]
