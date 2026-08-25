"""bge-m3 服务单元测试。

要点：mock 掉 SentenceTransformer，不下载真实模型（2GB），只验证：
- health 探针（不加载模型）
- /embed 入参校验、正常路径、异常→500
- 模型懒加载只执行一次
"""

from unittest.mock import MagicMock, patch

from fastapi.testclient import TestClient

import main


def _fresh_client():
    # 每个测试重置全局 _model，避免跨测试污染
    main._model = None
    return TestClient(main.app)


def test_health_no_model():
    client = _fresh_client()
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok", "model_loaded": False}


def test_health_model_loaded():
    client = _fresh_client()
    main._model = MagicMock()
    resp = client.get("/health")
    assert resp.json()["model_loaded"] is True


def test_embed_empty_texts_422():
    client = _fresh_client()
    resp = client.post("/embed", json={"texts": []})
    assert resp.status_code == 422


def test_embed_ok():
    client = _fresh_client()
    fake_model = MagicMock()

    class _FakeEmbeddings:
        """模拟真实 encode 返回的 numpy 数组（_encode 里调用 .tolist()）。"""

        def tolist(self):
            return [[0.1, 0.2], [0.3, 0.4]]

    fake_model.encode.return_value = _FakeEmbeddings()
    with patch("main._model", fake_model):
        resp = client.post("/embed", json={"texts": ["你好", "世界"]})
    assert resp.status_code == 200
    body = resp.json()
    assert body["dim"] == 2
    assert len(body["vectors"]) == 2
    # normalize 参数透传给模型
    fake_model.encode.assert_called_once_with(
        ["你好", "世界"], normalize_embeddings=True, convert_to_numpy=True
    )


def test_embed_inference_error_500():
    client = _fresh_client()
    with patch("main._encode", side_effect=RuntimeError("模型加载失败")):
        resp = client.post("/embed", json={"texts": ["你好"]})
    assert resp.status_code == 500
    assert "embedding 失败" in resp.json()["detail"]


def test_load_model_once():
    """懒加载：并发/多次调用只构造一次模型。"""
    main._model = None
    with patch("sentence_transformers.SentenceTransformer") as m:
        main._load_model()
        main._load_model()
    assert m.call_count == 1
