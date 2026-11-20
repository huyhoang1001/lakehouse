#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Fetch the extra JARs the Day 3 Delta jobs need, into ./jars/ (gitignored).
#
# Why a separate fetch instead of committing the JARs: they are ~4 MB of
# binaries. The Day 3 Terraform module loads its Delta JAR from S3
# (--extra-jars); locally run-glue.sh picks it up from ./jars, which is the
# same idea with a local file instead of an S3 object.
#
# Why Delta 2.3.0 and not the delta-spark_2.13-4.1.0 jar shipped under
# instruction/: that one is a Scala 2.13 / Spark 4.x build, while the local
# Glue image (and AWS Glue 4.0) is Scala 2.12 / Spark 3.3. Delta 2.4.0 is also
# rejected -- it references org.apache.spark.sql.catalyst.expressions.Empty2Null,
# which the Glue image's Amazon-forked Spark 3.3.0 does not ship. 2.3.0 is the
# newest Delta build that runs cleanly on this runtime, and its antlr4-runtime
# dependency (4.8) is exactly the one bundled in the image.
#
# Idempotent: re-running only fetches what is missing. Safe to call from
# run-glue.sh before a Delta job.
# -----------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JARS_DIR="$HERE/jars"
DELTA_VERSION="2.3.0"
BASE="https://repo1.maven.org/maven2/io/delta"

mkdir -p "$JARS_DIR"

fetch() { # fetch <artifactId> <fileName>
  local artifact="$1" file="$2" url
  if [ -f "$JARS_DIR/$file" ]; then
    return 0
  fi
  url="$BASE/$artifact/$DELTA_VERSION/$file"
  echo "[fetch-jars] downloading $file"
  curl -fsSL --retry 3 --max-time 180 -o "$JARS_DIR/$file" "$url"
}

# delta-core pulls in delta-storage at runtime; both must be on the classpath.
fetch "delta-core_2.12"    "delta-core_2.12-${DELTA_VERSION}.jar"
fetch "delta-storage"      "delta-storage-${DELTA_VERSION}.jar"

echo "[fetch-jars] ready: $JARS_DIR"
