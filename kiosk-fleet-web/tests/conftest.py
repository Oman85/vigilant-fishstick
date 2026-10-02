"""Fixtures for the tests: the demo fleet (kfw.demo), the app on top of it,
and signed-in clients. Nothing here touches the network."""
from __future__ import annotations

import time

import pytest
from fastapi.testclient import TestClient

from kfw.app import create_app
from kfw.config import Settings
from kfw.demo import LEDGER_HEADER, FakeLauncher, build_kiosks, docs, write_events  # noqa: F401

ADMIN_PASS = "Correct-Horse-42!"
OP_PASS = "Battery-Staple-77?"


@pytest.fixture
def work(tmp_path):
    root = tmp_path / "kiosks"
    data = tmp_path / "data"
    data.mkdir()
    dirs = build_kiosks(root)
    settings = Settings(data_dir=data, root_template=str(root / "{0}"), autoscan=False, refresh_seconds=1,
                        offline_ok=True, parallel_hosts=4, host_timeout_seconds=30)
    return {"root": root, "data": data, "dirs": dirs, "settings": settings}


@pytest.fixture
def fleet(work):
    write_events(work["settings"].local_csv)
    with FakeLauncher(work["root"], work["dirs"]):
        yield work


class Api:
    def __init__(self, client: TestClient):
        self.c = client
        self.csrf = None

    def login(self, user, password):
        r = self.c.post("/api/login", json={"user": user, "password": password})
        if r.status_code == 200:
            self.csrf = r.json()["csrf"]
        return r

    def get(self, path, **kw):
        return self.c.get(path, **kw)

    def post(self, path, body=None, csrf=True, **kw):
        h = kw.pop("headers", {})
        if csrf and self.csrf:
            h["X-Fleet-Csrf"] = self.csrf
        return self.c.post(path, json=body if body is not None else {}, headers=h, **kw)

    def delete(self, path, **kw):
        return self.c.delete(path, headers={"X-Fleet-Csrf": self.csrf or ""}, **kw)

    def job(self, host, action, body=None, timeout=30):
        r = self.post(f"/api/kiosks/{host}/{action}", body or {})
        if r.status_code != 202:
            return r, None
        jid = r.json()["job"]
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            j = self.get(f"/api/jobs/{jid}").json()
            if j.get("done"):
                return r, j
            time.sleep(0.1)
        return r, None


@pytest.fixture
def app_for(fleet):
    made = []

    def make(**overrides):
        s = fleet["settings"]
        for k, v in overrides.items():
            setattr(s, k, v)
        app = create_app(s, background=False)
        st = app.state.kfw
        if not st.db.user("webadmin"):
            st.db.add_user("webadmin", "admin", ADMIN_PASS)
            st.db.add_user("webop", "operator", OP_PASS)
        client = TestClient(app)
        client.__enter__()
        st.cache.refresh(force=True)
        made.append(client)
        return app, client

    yield make
    for c in made:
        c.__exit__(None, None, None)


@pytest.fixture
def admin(app_for):
    app, client = app_for()
    a = Api(client)
    assert a.login("webadmin", ADMIN_PASS).status_code == 200
    a.app = app
    return a


@pytest.fixture
def operator(admin):
    o = Api(TestClient(admin.app))
    assert o.login("webop", OP_PASS).status_code == 200
    o.app = admin.app
    return o
