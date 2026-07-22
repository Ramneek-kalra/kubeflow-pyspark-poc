from pyspark.sql import SparkSession
from pyspark.sql.functions import avg, count, sum as spark_sum


spark = (
    SparkSession.builder
    .appName("kubeflow-pyspark-test")
    .getOrCreate()
)

data = [
    ("Engineering", "Alice", 90000),
    ("Engineering", "Bob", 80000),
    ("Sales", "Charlie", 70000),
    ("Sales", "Diana", 75000),
    ("Finance", "Eve", 85000),
]

employees = spark.createDataFrame(
    data,
    ["department", "employee", "salary"],
)

result = (
    employees
    .groupBy("department")
    .agg(
        count("*").alias("employee_count"),
        spark_sum("salary").alias("total_salary"),
        avg("salary").alias("average_salary"),
    )
    .orderBy("department")
)

print("Input data:")
employees.show(truncate=False)

print("Department summary:")
result.show(truncate=False)

assert employees.count() == 5
assert result.count() == 3

print("PYSPARK_JOB_TEST_SUCCESS")

spark.stop()