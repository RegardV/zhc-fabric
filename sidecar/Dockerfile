FROM python:3.12-slim
WORKDIR /app
COPY sidecar/stub/server.py /app/server.py
ENV FABRIC_HOST=0.0.0.0
ENV FABRIC_PORT=7733
EXPOSE 7733
CMD ["python3", "/app/server.py"]
