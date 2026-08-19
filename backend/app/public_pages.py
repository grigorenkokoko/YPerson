# ruff: noqa: UP012

PRIVACY_HTML = """<!doctype html>
<html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Конфиденциальность YPerson</title></head>
<body><main><h1>Конфиденциальность YPerson</h1>
<p>Это техническая страница текущей предварительной версии YPerson.</p>
<p>Публичный backend отдаёт GET /config и GET /health без учётной записи. POST /sync отключён и возвращает 503. Текущий backend не использует базу данных и не сохраняет профили или APNs-токены.</p>
<p>Эта страница не является окончательной юридической политикой для публикации в App Store. До релиза будут добавлены сведения об ответственном владельце, контакте и фактической обработке данных мобильным приложением.</p>
</main></body></html>""".encode("utf-8")

SUPPORT_HTML = """<!doctype html>
<html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Поддержка YPerson</title></head>
<body><main><h1>Поддержка YPerson</h1>
<p>Это техническая страница поддержки предварительной версии YPerson.</p>
<p>Синхронизация и удалённые push-уведомления пока недоступны.</p>
<p><a href="https://github.com/grigorenkokoko/YPerson/issues">Сообщить о технической проблеме</a></p>
<p>Окончательные контакты поддержки и модерации должны быть утверждены до публикации в App Store.</p>
</main></body></html>""".encode("utf-8")
