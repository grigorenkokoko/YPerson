"""Production-entrypoint behavior tests."""

import uvicorn

from app import serve


def test_entrypoint_reuses_module_app_and_disables_uvicorn_access_logging() -> None:
    config = serve.build_config()

    assert isinstance(config, uvicorn.Config)
    assert config.app is serve.app
    assert config.host == serve.app.state.settings.host
    assert config.port == serve.app.state.settings.port
    assert config.access_log is False
    assert config.log_config is None
