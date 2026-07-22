import argparse
import time

from pyspark.sql import SparkSession


parser = argparse.ArgumentParser()
parser.add_argument("--sleep-seconds", type=int, default=0)
args = parser.parse_args()

spark = SparkSession.builder.appName("kubeflow-pyspark-jobs-smoke").getOrCreate()

rows = spark.range(1, 101)
total = rows.groupBy().sum("id").first()[0]
print(f"PYSPARK_JOBS_SMOKE_SUM={total}")

assert total == 5050
if args.sleep_seconds:
    time.sleep(args.sleep_seconds)
spark.stop()
