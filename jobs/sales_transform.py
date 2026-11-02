import sys

from pyspark.sql import SparkSession, functions as F

src, db, table, table_path = sys.argv[1:5]

spark = (
    SparkSession.builder
    .appName("team28c-sales-transform")
    .enableHiveSupport()
    .getOrCreate()
)
sc = spark.sparkContext
print(f"[1] Spark {spark.version}, master={sc.master}, application={sc.applicationId}")
print(f"[2] HDFS: fs.defaultFS={sc._jsc.hadoopConfiguration().get('fs.defaultFS')}")

raw = spark.read.option("header", "true").csv(src)
print(f"[3] Прочитано из HDFS {src}: {raw.count()} строк, схема: {raw.dtypes}")

clean = (
    raw.select(
        F.col("id").cast("bigint").alias("id"),
        F.to_date("sale_date", "yyyy-MM-dd").alias("sale_date"),
        F.trim("region").alias("region"),
        F.lower(F.trim("product")).alias("product"),
        F.col("quantity").cast("int").alias("quantity"),
        F.col("price").cast("decimal(10,2)").alias("price"),
    )
    .filter(F.col("sale_date").isNotNull() & (F.col("quantity") > 0) & F.col("price").isNotNull())
    .withColumn("revenue", (F.col("quantity") * F.col("price")).cast("decimal(14,2)"))
    .withColumn("sale_year", F.year("sale_date"))
    .withColumn("sale_month", F.month("sale_date"))
)

monthly = (
    clean.groupBy("sale_year", "sale_month", "region", "product")
    .agg(
        F.count("*").alias("orders"),
        F.sum("quantity").cast("bigint").alias("units"),
        F.sum("revenue").cast("decimal(16,2)").alias("revenue"),
        F.round(F.avg("price"), 2).cast("double").alias("avg_price"),
    )
    .select("region", "product", "orders", "units", "revenue", "avg_price", "sale_year", "sale_month")
)
print(f"[4] Трансформации: приведение типов, очистка, revenue = quantity * price, агрегация по месяцу/региону/товару -> {monthly.count()} строк")
monthly.printSchema()

spark.sql(f"CREATE DATABASE IF NOT EXISTS {db}")
(
    monthly.repartition("sale_year", "sale_month")
    .write.mode("overwrite")
    .format("orc")
    .partitionBy("sale_year", "sale_month")
    .option("path", table_path)
    .saveAsTable(f"{db}.{table}")
)
print(f"[5] Записано с партиционированием по sale_year, sale_month в {table_path}")
print(f"[6] Сохранено как таблица {db}.{table}")
spark.sql(f"SHOW PARTITIONS {db}.{table}").show(truncate=False)
(
    spark.table(f"{db}.{table}")
    .groupBy("sale_year", "sale_month")
    .agg(F.sum("orders").alias("orders"), F.sum("revenue").alias("revenue"))
    .orderBy("sale_year", "sale_month")
    .show()
)
spark.stop()
