FROM google/cloud-sdk:slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends python3-pip python3-venv \
 && rm -rf /var/lib/apt/lists/*
ENV PATH="/opt/venv/bin:${PATH}"
RUN python3 -m venv /opt/venv

WORKDIR /app
COPY pyproject.toml README.md ./
COPY fds_gestun ./fds_gestun
COPY deploy ./deploy
COPY fds_gestun_training_set.csv fds_gestun_features_179.csv ./
RUN pip install --no-cache-dir .

# Bake the model in so the container is reproducible and start-up does no training.
RUN fds-gestun train

RUN useradd --create-home --uid 10001 app && chown -R app /app
USER app

# google-cloud-sdk provides bq + gsutil for the scheduled entry point
ENTRYPOINT []
CMD ["fds-gestun", "--help"]
