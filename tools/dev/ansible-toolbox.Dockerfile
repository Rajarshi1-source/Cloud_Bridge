# Pinned Ansible toolchain for local checks and CI: lint, syntax-check and Molecule (docker driver,
# talking to the host's Docker through the mounted socket). ansible-core 2.21 needs Python >= 3.12.
FROM docker:29-cli AS docker-cli

FROM python:3.13-slim

# Molecule's docker connection plugin shells out to the docker CLI (the daemon is the host's, via the socket).
COPY --from=docker-cli /usr/local/bin/docker /usr/local/bin/docker

RUN apt-get update \
 && apt-get install -y --no-install-recommends git openssh-client rsync \
 && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir \
      ansible-core==2.21.5 \
      ansible-lint==26.10.1 \
      molecule==26.10.0 \
      "molecule-plugins[docker]==26.10.12" \
      boto3 botocore google-auth requests

# Collections Molecule needs but the playbooks don't (the playbooks' own pins live in ansible/requirements.yml).
RUN ansible-galaxy collection install community.docker:==5.4.0

WORKDIR /work
