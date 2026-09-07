## Короткий вывод

Переезд AdaMCP на CLI-рельсы может дать большой профит, **если CLI станет стабильным “ядром автоматизации”**, а MCP останется тонким транспортным/интеграционным слоем поверх него.

То есть не обязательно выбирать “MCP или консоль”. Лучший вариант, вероятно:

> **AdaCLI как canonical automation layer**  
> **AdaMCP как adapter/server, который вызывает тот же CLI / SDK**

Так мы получаем воспроизводимость, локальный дебаг, CI/CD, автоскрипты, скиллы агентов и независимость от MCP-рантайма — не теряя возможность работать через MCP там, где это удобно.

---

# Что именно дает переезд AdaMCP на CLI

## 1. Воспроизводимость и дебаг “как у обычного инженера”

MCP-инструменты часто выглядят как “черный ящик”:

- агент вызвал tool;
- что именно произошло — видно не всегда;
- повторить руками сложно;
- логи могут быть разрозненными;
- поведение зависит от MCP-клиента/агента/сессии.

CLI решает это:

```bash
ada device list
ada app install --device pixel-7 ./build.apk
ada web open --url https://example.com
ada test run --suite smoke
ada logs tail --device pixel-7
```

Любую операцию можно:

- скопировать из лога;
- запустить руками;
- положить в README;
- запустить в CI;
- завернуть в bash/python/node script;
- сравнить до/после;
- воспроизвести вне агента.

Это очень сильное свойство.

---

## 2. CLI можно использовать без агента и без MCP

Если вся логика живет только в MCP server, то она полезна в основном агенту.

Если логика живет в CLI, она полезна:

- людям;
- агентам;
- CI;
- локальным dev scripts;
- GitHub Actions;
- Docker/remote environments;
- IDE tasks;
- cron jobs;
- тестовым пайплайнам;
- smoke/regression automation.

То есть CLI превращает AdaMCP из “набора tools для агента” в **полноценную automation platform**.

---

## 3. MCP становится не источником правды, а адаптером

Архитектура может быть такой:

```text
                 ┌────────────┐
                 │ Human user │
                 └─────┬──────┘
                       │
                       ▼
                    Ada CLI
                       │
        ┌──────────────┼──────────────┐
        ▼              ▼              ▼
   Device layer    Browser layer    App layer
        ▲              ▲              ▲
        └──────────────┼──────────────┘
                       │
                    Ada SDK/Core
                       ▲
                       │
                 Ada MCP Server
                       ▲
                       │
                   AI Agent
```

Или еще проще:

```text
AI Agent -> MCP tool -> Ada CLI command -> Ada Core
Human    -> terminal -> Ada CLI command -> Ada Core
CI       -> script   -> Ada CLI command -> Ada Core
```

Профит: один и тот же backend действий, разные интерфейсы.

---

# По твоим пунктам

## “Агент будет дегать tooling тогда, когда будет запущен проект”

Да, это важный плюс.

Если CLI поставляется вместе с проектом или workspace, агент может сам обнаружить доступные команды:

```bash
ada --help
ada doctor
ada capabilities
ada devices
ada project status
```

Это дает агенту:

- introspection;
- self-check;
- понятный список возможностей;
- диагностику окружения;
- меньше зависимости от заранее зарегистрированных MCP tools;
- возможность работать в новых проектах без ручной настройки MCP.

Особенно полезны команды:

```bash
ada doctor
ada capabilities --json
ada config print
ada env check
ada targets list --json
ada actions list --json
```

Если CLI умеет отдавать machine-readable JSON, агент может сам понять, что доступно.

Например:

```bash
ada capabilities --json
```

```json
{
  "devices": {
    "android": true,
    "ios": false
  },
  "browser": {
    "chromium": true,
    "remoteDebugging": true
  },
  "appium": false,
  "playwright": true,
  "adb": true
}
```

Это лучше, чем надеяться, что MCP tool list всегда отражает реальное состояние среды.

---

## “Агент сможет сделать себе скиллы и автоматизировать работу — но как нам это поможет?”

Поможет, если CLI будет стабильным контрактом.

Скилл агента обычно должен отвечать на вопросы:

- как собрать проект;
- как запустить;
- как проверить;
- как открыть приложение;
- как снять логи;
- как прогнать smoke test;
- как воспроизвести баг;
- как собрать артефакты.

Если есть CLI, скилл становится простым и надежным:

```markdown
# Android Debug Skill

Use:
- `ada device list` to find connected devices
- `ada app install --build latest`
- `ada app launch --package com.example`
- `ada logs tail --since 2m`
- `ada screenshot take`
- `ada test smoke`
```

Без CLI скилл должен описывать MCP tools, их аргументы, ограничения конкретного клиента, нюансы runtime. Это менее переносимо.

### Конкретный профит для агента

Агент сможет:

1. Проверять окружение:
   ```bash
   ada doctor
   ```

2. Сам выбирать target:
   ```bash
   ada targets list --json
   ```

3. Запускать стандартные workflow:
   ```bash
   ada workflow run android-smoke
   ```

4. Сохранять и переиспользовать команды:
   ```bash
   ada recipe create reproduce-login-bug
   ```

5. Автоматизировать повторяемые сценарии:
   ```bash
   ada app reset
   ada app launch
   ada ui tap --text "Login"
   ada ui type --field email --value test@example.com
   ada logs collect --output artifacts/logs.zip
   ```

6. Делиться этим с человеком:
   > “Чтобы воспроизвести, выполни `ada workflow run repro-login-crash`”.

Это превращает действия агента из эфемерных tool calls в **артефакты процесса разработки**.

---

## “Но мы не сможем дебажить remote приложения на телефонах или web?”

Не обязательно. Это зависит не от MCP vs CLI, а от backend capabilities.

CLI вполне может работать с remote/mobile/web, если внутри есть соответствующие адаптеры:

### Для Android

CLI может использовать:

- `adb`;
- Appium;
- Maestro;
- Detox;
- uiautomator;
- scrcpy/minicap;
- remote device farm API;
- BrowserStack/Sauce Labs/Firebase Test Lab.

Примеры:

```bash
ada device list
ada android connect --adb tcpip://192.168.1.42:5555
ada android logs tail
ada android screenshot
ada android shell input tap 100 200
ada app install ./app.apk
```

### Для iOS

CLI может использовать:

- `xcrun simctl`;
- WebDriverAgent;
- Appium;
- XCUITest;
- physical device provider APIs.

Примеры:

```bash
ada ios simulators list
ada ios boot "iPhone 15"
ada ios install ./App.app
ada ios logs tail
```

### Для web

CLI может использовать:

- Playwright;
- Chrome DevTools Protocol;
- Selenium;
- remote browser CDP endpoint;
- BrowserStack/Sauce;
- local Chrome debugging port.

Примеры:

```bash
ada web open --url https://app.example.com
ada web screenshot
ada web console tail
ada web eval 'window.location.href'
ada web click --text "Login"
ada web trace start
```

### Для remote web/app

CLI может принимать remote endpoint:

```bash
ada web connect --cdp ws://remote-host:9222/devtools/browser/...
ada android connect --adb remote-device:5555
ada cloud device acquire --provider browserstack --os android --version 14
```

То есть remote debug не теряется.  
Наоборот, CLI может сделать его более явным и повторяемым.

---

# Где MCP реально хуже консоли

## 1. MCP плохо подходит как единственный интерфейс для сложной диагностики

MCP tool call обычно атомарный:

```text
call tool X with args Y
```

Но реальная диагностика часто интерактивная:

```bash
adb devices
adb shell pm list packages
adb logcat | grep MyApp
curl localhost:3000/health
ps aux | grep chrome
```

CLI/terminal лучше для exploratory debugging.

---

## 2. MCP зависит от клиента

Один MCP client может хорошо отображать tool output, другой — плохо.

CLI output всегда можно увидеть, pipe-нуть, grep-нуть, сохранить:

```bash
ada logs tail | grep ERROR
ada test run --json > result.json
ada screenshot take --output fail.png
```

---

## 3. MCP tools сложнее версионировать как публичный контракт

CLI команды проще документировать и стабилизировать:

```bash
ada app install
ada app launch
ada logs collect
```

MCP schema может меняться, но пользователи чаще ожидают стабильности от CLI.

---

## 4. MCP сложнее использовать в CI

Можно, но это неестественно.

CI хочет:

```bash
npm run test
ada workflow run smoke
ada artifacts collect
```

А не “подними MCP server, подключи client, вызови tool”.

---

# Где MCP лучше CLI

Важно не уйти в другую крайность.

MCP хорош для:

## 1. Structured tool discovery

Агенту удобно видеть tools как функции:

```ts
install_app(deviceId, apkPath)
take_screenshot(deviceId)
query_dom(selector)
```

Это лучше, чем парсить help text.

Решение: CLI должен иметь JSON discovery:

```bash
ada actions list --json
ada schema print --json
```

А MCP server может строить tools из этого schema.

---

## 2. Богатые typed inputs

MCP tool schema может явно сказать:

```json
{
  "deviceId": "string",
  "timeoutMs": "number",
  "resetApp": "boolean"
}
```

CLI flags менее типизированы.

Решение: иметь общий schema/core, из которого генерируются и CLI, и MCP tools.

---

## 3. Resource exposure

MCP может удобно отдавать ресурсы:

- screenshots;
- logs;
- traces;
- DOM snapshots;
- device state;
- project metadata.

CLI тоже может, но через файлы/stdout.

Решение: CLI должен складывать artifacts в понятную директорию:

```bash
ada artifacts list
ada artifacts open latest
ada logs collect --output artifacts/logs.zip
```

---

## 4. Агенту не всегда удобно работать с interactive CLI

Если CLI требует интерактивного ввода, прогресс-бары, TTY-only UI — агенту хуже.

Решение: все agent-facing команды должны иметь non-interactive режим:

```bash
--json
--yes
--no-color
--timeout
--output
--quiet
```

---

# Рекомендуемая стратегия

## Не “заменить MCP на CLI”, а “вынести ядро в CLI/Core”

Лучший путь:

```text
Ada Core / SDK
  ├─ Ada CLI
  └─ Ada MCP Server
```

Где:

- Core содержит реальные действия;
- CLI — основной человеко/CI/агентный интерфейс;
- MCP — thin adapter для AI-native клиентов;
- оба используют один и тот же schema/actions registry.

---

# Что должно быть в AdaCLI, чтобы это было полезно агентам

## 1. Stable command surface

Пример верхнего уровня:

```bash
ada doctor
ada capabilities
ada project status

ada device list
ada device connect
ada device info

ada app build
ada app install
ada app launch
ada app reset
ada app uninstall

ada web open
ada web click
ada web type
ada web screenshot
ada web console
ada web trace

ada mobile tap
ada mobile type
ada mobile screenshot
ada mobile logs

ada test run
ada workflow run
ada artifacts collect
```

---

## 2. JSON mode для каждой команды

Каждая команда должна иметь:

```bash
--json
```

Например:

```bash
ada device list --json
```

```json
{
  "devices": [
    {
      "id": "emulator-5554",
      "platform": "android",
      "status": "online",
      "name": "Pixel_7_API_34"
    }
  ]
}
```

---

## 3. Exit codes как контракт

Например:

```text
0   success
1   generic failure
2   invalid args
3   missing dependency
4   no device
5   timeout
6   app not found
7   assertion failed
```

Агенту и CI это очень помогает.

---

## 4. Artifacts directory

Все побочные результаты должны попадать в predictable place:

```text
.ada/
  artifacts/
    2025-...
      screenshot.png
      logs.txt
      trace.zip
      result.json
```

Команды:

```bash
ada artifacts list
ada artifacts latest
ada artifacts collect
```

---

## 5. `ada doctor`

Обязательная команда.

Она должна проверять:

- установлен ли adb;
- видны ли устройства;
- доступен ли Chrome/CDP;
- установлен ли Playwright;
- есть ли нужные env vars;
- доступен ли remote provider;
- есть ли project config;
- какие capabilities включены/выключены.

---

## 6. `ada capabilities --json`

Это особенно важно для агента.

Команда должна отвечать не “что теоретически умеет Ada”, а “что сейчас реально доступно”.

---

## 7. `ada workflow`

Поверх низкоуровневых команд нужны workflow:

```bash
ada workflow run smoke
ada workflow run reproduce-login-bug
ada workflow run collect-debug-bundle
```

Это место, где агент может создавать/предлагать автоматизацию.

---

# Как агентские скиллы могут использовать CLI

Скилл не должен быть “магией”. Он должен быть тонкой инструкцией поверх CLI.

Например:

```markdown
## Debug Android crash

1. Run `ada doctor --json`.
2. Run `ada device list --json`.
3. Install latest build with `ada app install --build latest`.
4. Launch with `ada app launch`.
5. Tail logs with `ada logs tail --since 2m`.
6. If crash occurs, run `ada artifacts collect --include logs,screenshot,trace`.
```

Польза:

- скилл переносим между агентами;
- человек может повторить;
- CI может использовать те же команды;
- агент может улучшать workflow постепенно.

---

# Главные риски CLI-переезда

## Риск 1. CLI станет просто “тонкой оберткой над MCP”

Это плохой вариант.

Если CLI вызывает MCP server, то мы не избавились от зависимости. Лучше наоборот:

```text
MCP calls CLI/Core
```

или:

```text
CLI and MCP both call Ada Core
```

---

## Риск 2. CLI будет human-friendly, но agent-hostile

Например:

- цветной вывод без `--no-color`;
- progress bars;
- prompts;
- нестабильный текст;
- отсутствие JSON;
- отсутствие exit codes;
- команды зависят от current directory без явного config.

Нужно сразу проектировать CLI как automation-first.

---

## Риск 3. Дублирование логики между MCP и CLI

Если actions будут реализованы дважды, все быстро разъедется.

Нужен общий action registry/core.

---

## Риск 4. Потеря typed schema

MCP schema полезен. Не надо его выбрасывать.

Лучше хранить schema на уровне core:

```text
actions/install_app.schema.json
actions/take_screenshot.schema.json
actions/open_web.schema.json
```

И из него генерировать:

- CLI flags/help;
- MCP tool schemas;
- docs;
- tests.

---

# Возможная целевая архитектура

```text
packages/
  ada-core/
    actions/
      device.list
      app.install
      app.launch
      web.open
      web.screenshot
    schemas/
    providers/
      android-adb/
      ios-simctl/
      playwright/
      cdp/
      appium/
      browserstack/

  ada-cli/
    bin/ada
    commands/
    output/
      json
      human

  ada-mcp/
    server
    tool-registry
    adapters-to-core

  ada-workflows/
    smoke.yaml
    collect-debug.yaml
```

---

# Приоритетный план миграции

## Phase 1. Inventory текущего AdaMCP

Собрать список всех MCP tools:

- имя tool;
- входные аргументы;
- выходной формат;
- side effects;
- зависимости;
- какие remote/mobile/web scenarios покрывает;
- какие tools критичны;
- какие experimental.

Результат:

```text
MCP Tool Inventory
```

---

## Phase 2. Спроектировать Action Registry

Для каждого действия описать canonical action:

```yaml
id: app.install
description: Install app on target device
input:
  deviceId: string
  artifactPath: string
output:
  installed: boolean
  packageName: string
errors:
  - NO_DEVICE
  - INSTALL_FAILED
  - TIMEOUT
```

Это станет источником правды для CLI и MCP.

---

## Phase 3. Сделать минимальный AdaCLI

Начать не со всего, а с самого ценного:

```bash
ada doctor
ada capabilities --json
ada device list --json
ada app install
ada app launch
ada logs tail
ada screenshot take
ada artifacts collect
```

Это уже даст 80% пользы.

---

## Phase 4. Подключить MCP к тому же core

MCP tools должны стать thin wrappers:

```text
MCP install_app -> core action app.install
CLI ada app install -> core action app.install
```

---

## Phase 5. Добавить workflows

Например:

```bash
ada workflow run mobile-smoke
ada workflow run web-smoke
ada workflow run collect-debug-bundle
```

---

## Phase 6. Agent skill layer

Сделать набор скиллов/гайдов:

- Android debug skill;
- Web debug skill;
- Release smoke skill;
- Remote device skill;
- Bug reproduction skill.

Все они должны ссылаться на CLI commands.

---

# Что я бы считал Definition of Done для такого переезда

Минимально успешный результат:

1. Все критичные AdaMCP actions имеют CLI-эквивалент.
2. CLI команды работают без интерактивного ввода.
3. У каждой команды есть `--json`.
4. Есть `ada doctor`.
5. Есть `ada capabilities --json`.
6. MCP server использует тот же core/action registry, что и CLI.
7. Можно выполнить один mobile smoke scenario полностью из CLI.
8. Можно выполнить один web debug scenario полностью из CLI.
9. Агент может по `ada capabilities --json` понять, какие действия доступны.
10. Человек может повторить действия агента командой из лога.

---

# Ответ на главный вопрос

## Какой профит мы получим?

Главный профит:

1. **Воспроизводимость** — действия агента можно повторить руками.
2. **CI-ready автоматизация** — те же команды можно запускать в пайплайнах.
3. **Меньше lock-in в MCP** — MCP становится адаптером, не ядром.
4. **Проще дебажить** — terminal-first troubleshooting.
5. **Лучше agent skills** — скиллы становятся инструкциями поверх стабильного CLI.
6. **Единый контракт для людей и агентов** — одна команда работает везде.
7. **Можно сохранить remote/mobile/web debugging** — если backend capabilities остаются в core.
8. **Проще развивать workflows** — `ada workflow run ...`.
9. **Лучше логирование и artifacts** — screenshots/logs/traces становятся файлами.
10. **Проще onboarding** — “поставь CLI и выполни `ada doctor`”.

---

# Моя рекомендация

Я бы не формулировал это как “MCP хуже, переезжаем на CLI”.

Лучше так:

> AdaMCP нужно превратить из самостоятельного слоя логики в MCP-адаптер поверх Ada Core.  
> Главным публичным и воспроизводимым интерфейсом сделать AdaCLI.  
> MCP оставить для AI-native интеграции, discovery и typed tool calls.

Так мы получим преимущества консоли, но не потеряем преимущества MCP.
