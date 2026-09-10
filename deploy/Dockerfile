FROM python:3.11-slim

WORKDIR /app
COPY pyproject.toml README.md ./
COPY fds_gestun ./fds_gestun
COPY fds_gestun_training_set.csv fds_gestun_features_179.csv ./
RUN pip install --no-cache-dir .

# Bake the model in so the container is reproducible and start-up does no training.
RUN fds-gestun train

RUN useradd --create-home --uid 10001 app && chown -R app /app
USER app

ENTRYPOINT ["fds-gestun"]
CMD ["--help"]
