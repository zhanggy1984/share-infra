# P1.3 连通性验证：从 shared-infra 网络内按逻辑名 milvus 建/写/检/删
from pymilvus import connections, utility, Collection, FieldSchema, CollectionSchema, DataType

connections.connect(alias="default", host="milvus", port="19530")
NAME = "shared_probe"
try:
    if utility.has_collection(NAME):
        utility.drop_collection(NAME)
    fields = [
        FieldSchema("pk", DataType.INT64, is_primary=True),
        FieldSchema("vec", DataType.FLOAT_VECTOR, dim=4),
    ]
    col = Collection(NAME, CollectionSchema(fields, "P1 probe"), consistency_level="Strong")
    col.create_index("vec", {"index_type": "FLAT", "metric_type": "L2"})
    col.insert([[1, 2], [[0.1, 0.2, 0.3, 0.4], [0.5, 0.5, 0.5, 0.5]]])
    col.flush()
    col.load()
    res = col.search([[0.1, 0.2, 0.3, 0.4]], "vec", param={"metric_type": "L2", "params": {}}, limit=1)
    print("MILVUS_OK nearest id:", res[0][0].id)
    assert int(res[0][0].id) == 1
    utility.drop_collection(NAME)
    print("MILVUS_OK: 建/写/检/删 全链路通过")
finally:
    connections.disconnect("default")
