FROM python:3.11.2-alpine3.17

# Allow statements and log messages to immediately appear in the Knative logs
ENV PYTHONUNBUFFERED True

WORKDIR /app

COPY ./development/gcp/cloud-run/slack-message-sender/slack-message-sender.py .
COPY ./development/gcp/cloud-run/slack-message-sender/requirements.txt .

RUN pip install --no-cache-dir --upgrade -r requirements.txt && \
	apk add --no-cache ca-certificates

CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "4", "--timeout", "0", "slack-message-sender:app"]
