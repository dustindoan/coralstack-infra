# CoralStack admin panel — stdlib-Python action panel for the admin plane.
#
# Base = postgres:15-alpine for the same reason as backup/ and ente-janitor/:
# the psql client is version-matched to ente-postgres:15. Python comes from
# apk; app.py is stdlib-only, so there is no pip and no dependency tree.
FROM postgres:15-alpine

RUN apk add --no-cache python3 tzdata

COPY app.py /usr/local/bin/admin-panel.py

# The postgres base image sets ENTRYPOINT/CMD for running a database; override
# both so the container runs the panel instead.
ENTRYPOINT ["python3", "-u", "/usr/local/bin/admin-panel.py"]
CMD []
