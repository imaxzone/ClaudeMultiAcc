# Шаг 6: пересборка Claude 2nd движком ClaudeMultiAcc

Этот ранбук нужен только для клона `/Applications/Claude 2nd.app`, собранного старым скриптом `build-2nd.sh` ещё до
ClaudeMultiAcc. Если вы поставили ClaudeMultiAcc из релиза и добавляете приложения через «+ Добавить», он вам не
нужен.

Ранбук выполняет пользователь, вручную и в удобное время. В автоматических сессиях шаг 6 не запускается: там
разрешена только проверка `--check`.

## Зачем

Сейчас `/Applications/Claude 2nd.app` собран старым скриптом `build-2nd.sh`. У этой сборки есть известные дефекты:

- подпись ad hoc с `--deep`: с хелперов сняты entitlements, iOS-симулятор падает (SIGABRT); `Claude.real` подписан
  без `-i`, поэтому не работают уведомления (`UNErrorDomain 1`); hardened runtime нет;
- апдейтер клона жив: раз в час он скачивает релиз (около 878 МБ) и не может его установить. 23.09 был случай,
  когда ShipIt перезапустил клон на профиле основного приложения (тогда у клона был вендорский bundle id). Пересборка
  апдейтер не убирает — он остаётся пассивным, а профиль при любом перезапуске задаёт лаунчер (см. ниже);
- разрешения TCC и «Всегда разрешать» для «Claude Safe Storage» привязаны к cdhash и слетают после каждой
  пересборки;
- лаунчер на bash: `pgrep -x ShipIt` путается с ShipIt от GitHub Desktop, сессия изнутри Claude 2nd может подменить
  живой бандл, у `NSRunningApplication` pid −1, от двух процессов на одном профиле защиты нет;
- обе копии заявляют `msauth…` и одинаковые типы документов, поэтому в «Открыть с помощью» появляются дубли.

После пересборки вложенный код остаётся с подписью Anthropic, как его выпустил вендор. Внешний бандл и
`Claude.real` подписываются постоянной локальной подписью: hardened runtime, `-i com.anthropic.claudefordesktop2`,
отфильтрованные entitlements. `Contents/Frameworks/` (хелперы, Squirrel с ShipIt) остаётся побайтно вендорским и не
переподписывается: хелперы с library validation не загрузят фреймворк с другим Team ID. Апдейтер клона остаётся
пассивным: релиз он может скачать, но установить не сможет — у клона другой designated requirement, а ShipIt не
тронет чужой бандл. Вместо bash-скрипта ставится компилируемый лаунчер
`CloneLauncher` с блокировкой профиля. Плагина Dock у клона нет.

Иконка: бейдж «2nd» рисуется прямо в `Contents/Resources/electron.icns` клона ещё до подписи, внутри формы иконки,
поэтому в Доке, Finder и ⌘Tab нет серой рамки. `CFBundleIconName` из `Info.plist` клона убирается, и macOS показывает
`electron.icns` с бейджем; `Assets.car` не меняется (из него Claude сам загружает картинки). Finder-иконка
(`Icon\r`) больше не ставится, поэтому установленный клон проходит `codesign --verify --deep --strict`.

## Предусловия

1. **Закройте Claude 2nd** (⌘Q). Проверка ищет приложение по bundle id (`NSRunningApplication` и
   `lsappinfo find bundleid=com.anthropic.claudefordesktop2`) и по блокировке профиля. `pgrep` не используется.
2. **Запускайте не из Claude 2nd.** Команды выполняйте в Терминале или в сессии основного Claude. Проверка
   `not-hosted-inside` обходит цепочку родительских процессов и не пропустит запуск изнутри заменяемого бандла.
3. **Постоянная подпись, один раз.** Подходит любая из двух:
   - подпись, которую ClaudeMultiAcc создаёт сам при первом «+ Добавить» в меню: отдельный файл связки ключей
     `~/Library/Application Support/ClaudeMultiAcc/signing/cmacc-signing.keychain-db`, без Терминала и без пароля
     связки «Вход»;
   - сертификат в связке «Вход» от скрипта:
     ```bash
     scripts/signing-setup.sh            # спросит «Create and import …? [y/N]», затем пароль связки ключей
     ```
     Скрипт создаёт сертификат «ClaudeMultiAcc Local Signing» и импортирует его в связку «Вход». Затем записывает
     `signing/identity.json` и `builder.signingIdentitySHA1` в `settings.json`. Посмотреть команды без выполнения
     можно так: `scripts/signing-setup.sh --dry-run`. Ключ импортируется неизвлекаемым и доступен только
     `/usr/bin/codesign`; после успешного импорта `key.pem` и `identity.p12` удаляются, остаётся `cert.pem`. При первой
     подписи macOS может спросить доступ `codesign` к ключу — нажмите **«Всегда разрешать»**.

   Сертификат не помечается доверенным, и это нормально. Эксперимент E2 (`docs/EXPERIMENTS.md`) показал, что
   `codesign` подписывает недоверенным self-signed сертификатом по SHA-1, а designated requirement
   (`certificate leaf = H"…"`) остаётся стабильным между пересборками.
4. **Поставьте ClaudeMultiAcc с командой `cmacc` в `PATH`** (см. «Сборка из исходников» в README):
   ```bash
   scripts/install.sh --link-cli      # ~/Applications/ClaudeMultiAcc.app и ссылка ~/.local/bin/cmacc
   ```
   Если `~/.local/bin` нет в `PATH`, вызывайте помощник по полному пути:
   `~/Applications/ClaudeMultiAcc.app/Contents/Helpers/cmacc` (у копии из `.dmg` —
   `/Applications/ClaudeMultiAcc.app/Contents/Helpers/cmacc`). Рядом с ним лежит `CloneLauncher` (только arm64, то
   есть только Mac на Apple Silicon). Этот ранбук есть и внутри приложения:
   `ClaudeMultiAcc.app/Contents/Resources/Help/RUNBOOK-step6.md`.
5. **Все проверки должны пройти (PASS):**
   ```bash
   cmacc instance rebuild second --check; echo "exit=$?"
   ```
   Команда ничего не меняет вне каталога данных. Она собирает `CloneSpec.second` в staging, проверяет сборку и
   удаляет её (флаг `--keep-staging` оставляет сборку). Ожидается 10 строк `PASS` и `exit=0`.

   Для сравнения, вывод 24.09 (Claude 2nd запущен, постоянной подписи ещё нет):
   ```
   PASS update-lock — free
   FAIL not-running — Claude 2nd (com.anthropic.claudefordesktop2) is running — quit it first
   PASS not-hosted-inside — no ancestor inside Claude 2nd.app; session hosted by /Applications/Claude.app (CLAUDE_CODE_DESKTOP_APP_VERSION=2.7032.0)
   FAIL identity-present — builder.signingIdentitySHA1 not set — open ClaudeMultiAcc and click + Add once: it creates the identity in its own keychain and checks it again before every build
   PASS disk-space — 41.0 GB free, 2.9 GB needed
   PASS vendor-idle — ShipIt idle
   PASS source-ok — 2.7032.0 team Q6L2SF6YDW
   PASS staging-build — verified, 20/20 smoke, adhoc — apply needs the permanent identity
   PASS backup-plan — ~/Library/Application Support/ClaudeMultiAcc/backup/legacy-Claude 2nd.app.20260924-081653
   PASS profile-intact — ~/Library/Application Support/ClaudeProfiles/second (launcher config matches)
   exit=1
   ```

| Проверка | Что значит |
|---|---|
| `update-lock` | `…/ClaudeMultiAcc/update.lock` свободен: UpdateWatcher или другая проверка сейчас ничего не собирает (иначе повторите через минуту) |
| `not-running` | Claude 2nd не запущен (NSRunningApplication, lsappinfo, блокировка профиля) |
| `not-hosted-inside` | ни один родительский процесс не лежит внутри `/Applications/Claude 2nd.app/` |
| `identity-present` | SHA-1 записан в настройках, `identity.json` на месте, сертификат найден в отдельной связке ClaudeMultiAcc или в связке ключей пользователя (только чтение) |
| `disk-space` | свободно не меньше 2 ГБ плюс размер `Claude.app` |
| `vendor-idle` | ShipIt официального Claude сейчас ничего не ставит. Скачанное обновление, которое ждёт закрытия Claude, не мешает (PASS, «update pending … safe to build»); FAIL только пока обновление устанавливается — повторите через минуту |
| `source-ok` | `/Applications/Claude.app` подписан Anthropic (Q6L2SF6YDW) и проходит `codesign --verify` |
| `staging-build` | полная сборка в staging проверена (подпись и статический смоук) |
| `backup-plan` | каталог бэкапа на том же томе, что `/Applications`, и имя бэкапа свободно (для сборки старым скриптом — с префиксом `legacy-`) |
| `profile-intact` | `ClaudeProfiles/second` существует, и лаунчер собранного клона указывает ровно на него |

## Что произойдёт

- **Первый запуск:** macOS спросит пароль для «Claude Safe Storage». Введите пароль входа и нажмите
  **«Всегда разрешать»**. С постоянной подписью это требуется один раз; при следующих пересборках requirement тот же.
- **Разрешения TCC** (уведомления, папки, микрофон, запись экрана или универсальный доступ для computer use)
  запрашиваются заново, потому что у бандла другая подпись.
- **Dock:** закрепите новый Claude 2nd заново: старый значок указывает на бэкап. Запустите новый Claude 2nd, уберите
  его значок из Dock и закрепите заново. Программно Dock не трогаем.
- **Вход не нужен:** профиль тот же (`~/Library/Application Support/ClaudeProfiles/second`). Если приложение всё же
  попросит войти, войдите один раз.
- **Хелперы** сохраняют вендорские bundle id и подпись Anthropic (`…claudefordesktop.helper` и т. п.). Так задумано:
  вложенный код не переподписывается.
- **Team ID:** в `Info.plist` клона остаётся `ElectronTeamID=Q6L2SF6YDW`, хотя бандл подписан локальной подписью.
  При первом запуске следите за логом `~/Library/Logs/ClaudeMultiAcc/launcher-second.log` и за окном приложения.
  Если что-то зависит от Team ID, это проявится именно здесь. При проблемах сделайте откат (ниже).
- **`claude://`:** пересборка владельца схемы не меняет. ClaudeMultiAcc сам берёт `claude://` только пока какой-то
  клон ждёт входа в аккаунт, и потом возвращает схему официальному Claude; Claude 2nd уже вошёл, поэтому входа не
  ждёт. Проверить владельца: `cmacc scheme owner`.

## Команды по шагам

```bash
cmacc instance rebuild second --check          # 10 × PASS, exit=0
cmacc instance rebuild second --apply          # спросит «Replace … ? [y/N]», ответьте y
```

`--apply` ещё раз проходит все проверки. Если хоть одна не пройдена, команда останавливается и ничего не трогает.
Дальше она собирает клон с постоянной подписью (бейдж «2nd» уже в иконке; intent `install`: запущенный клон
отклоняется), переносит `/Applications/Claude 2nd.app` в `…/ClaudeMultiAcc/backup/legacy-Claude 2nd.app.<дата-время>`
(и переименовывает у бэкапа `Info.plist` в `Info.plist.disabled`, чтобы LaunchServices не видел дубль), ставит новую
сборку на место, выполняет `lsregister -f`, записывает `signing/requirement.txt` и ставит у `second` в
`instances.json` `builtBy: "cmacc"`. Ожидаемый вывод:

```
Rebuilt /Applications/Claude 2nd.app; backup /Users/<вы>/Library/Application Support/ClaudeMultiAcc/backup/legacy-Claude 2nd.app.20260925-101500
Rollback: cmacc instance rollback second /Users/<вы>/Library/Application Support/ClaudeMultiAcc/backup/legacy-Claude 2nd.app.20260925-101500
```

Сохраните строку `Rollback:`. Без терминала (например, из скрипта) команда требует `--yes`.

Префикс `legacy-` отмечает бэкап сборки старого скрипта — единственную копию прежнего Claude 2nd. Автоочистка
бэкапов (UpdateWatcher хранит по два последних на клон) такие бэкапы никогда не удаляет; удалить его можно только
вручную, когда новая сборка проверена. Бэкапы следующих пересборок называются без префикса и чистятся как обычно.

### Если `--apply` остановился

- **`… is running — nothing was replaced`**: Claude 2nd запустили во время сборки (она идёт несколько минут).
  Ничего не заменено. Закройте Claude 2nd (⌘Q) и снова выполните
  `cmacc instance rebuild second --apply`.
- **`swapped, then register failed …`** (или `requirement`/`store`): новая сборка уже стоит на месте, но
  шаг после замены не выполнен — например, Claude 2nd запустили между заменой и регистрацией. Закройте Claude 2nd,
  выполните напечатанную команду `cmacc instance rollback second <путь бэкапа>` (вернёт прежнюю сборку), затем снова
  `cmacc instance rebuild second --apply`.
- **Команда прервалась между двумя переименованиями** (выключили питание, закрыли Терминал): прежнее приложение уже
  перенесено в бэкап, а новое ещё не встало на место. Посмотрите бэкапы и верните последний:
  ```bash
  ls "$HOME/Library/Application Support/ClaudeMultiAcc/backup"
  cmacc instance rollback second "$HOME/Library/Application Support/ClaudeMultiAcc/backup/<последний бэкап>"
  ```
  Если откат ответит `not a backup made by rebuild` (обрыв пришёлся между переносом и отключением `Info.plist`, и у
  бэкапа ещё обычный `Info.plist`), верните папку вручную:
  `mv "$HOME/Library/Application Support/ClaudeMultiAcc/backup/<последний бэкап>" "/Applications/Claude 2nd.app"`.
- **macOS «Управление приложениями» (App Management) запретила переименование внутри подписанного бандла**
  (`Operation not permitted`): замена сама откатывается, приложение остаётся прежним. Разрешите Терминалу
  «Управление приложениями» в Системных настройках → Конфиденциальность и безопасность и повторите `--apply`.
- **`… is running — nothing was restored`** при откате: закройте Claude 2nd и повторите ту же команду отката.
- **`… undoing it failed too — the app that was installed is now at <путь>`**: шаг не удался, и отменить его тоже не
  получилось. Команда называет, где сейчас лежит прежнее приложение; верните его в `/Applications/Claude 2nd.app`
  вручную (Finder или `mv`), затем снова выполните `--check`.

## Проверка

1. Запустите Claude 2nd из Dock или Finder. Процесс один,
   `lsappinfo info -only pid -app com.anthropic.claudefordesktop2` показывает настоящий pid. На macOS 27 команда
   печатает блок, поэтому номер извлекайте так же, как в `scripts/install.sh`:
   `lsappinfo info -only pid -app com.anthropic.claudefordesktop2 | grep -oE 'pid"? ?= ?[0-9]+' | grep -oE '[0-9]+'`.
2. **Чаты на месте:** в Claude 2nd видны все чаты, что были до пересборки.
3. **Уведомления** авторизуются: в логе нет `UNErrorDomain 1`, тестовое уведомление приходит.
4. **iOS-симулятор** больше не падает: нет новых `.ips` в `~/Library/Logs/DiagnosticReports/` с `ios-sim`.
5. **Подпись:**
   ```bash
   cmacc instance verify "/Applications/Claude 2nd.app"   # PASS codesign-verify-deep-strict, vendor-frameworks-intact …
   codesign --verify --deep --strict --verbose=2 "/Applications/Claude 2nd.app"   # valid on disk, satisfies DR
   codesign -dv --verbose=4 "/Applications/Claude 2nd.app" 2>&1 | grep -E 'Identifier|flags|Authority'
   ```
   У новой сборки нет Finder-иконки `Icon\r`, поэтому строгая проверка проходит. Строки `custom-icon`,
   `codesign-verify-deep` (без `--strict`) и `bundle-root-sealed` `cmacc instance verify` печатает только для клона,
   собранного прежней версией с Finder-иконкой; она исчезает при следующей пересборке.
   **Иконка:** в Dock, Finder и ⌘Tab — иконка Claude с бейджем «2nd», без серой рамки. Бейдж — часть самой иконки,
   отдельно ставить его не нужно (`cmacc instance icon` больше ничего не делает). Если Dock ещё показывает старую
   иконку, уберите значок из Dock и закрепите заново.
6. **Ссылки.** Тёплая доставка: при запущенном клоне выполните
   `open -a "/Applications/Claude 2nd.app" "claude://claude.ai/new?q=ping"`. Должен остаться один процесс
   `Claude.real`, и в окне появится подсказка «ping». Холодная доставка: то же при закрытом клоне. Вход через Google
   проверяется на клоне, который ждёт входа (новом или вышедшем из аккаунта): ClaudeMultiAcc сам временно берёт
   `claude://` и отдаёт ссылку входа этому клону, пункта меню для этого нет. Куда ушла бы ссылка, не открывая её:
   `cmacc route --dry-run '<ссылка>'`. После входа в `~/Library/Logs/Claude/main.log` должна быть строка
   `Starting ASWebAuth`, а не `Using system browser`. Эти проверки открывают `claude://` и поэтому выполняются только
   вручную.
7. **VM Cowork:** запустите Cowork-сессию с VM и запишите результат, загрузилась она или нет.
8. **Владелец схемы:** `cmacc scheme owner`. Пока ни один клон не ждёт входа, владелец — официальный Claude.
9. **Вендорские фреймворки:** `cmacc instance verify "/Applications/Claude 2nd.app"` показывает
   `PASS vendor-frameworks-intact` (все бандлы в `Contents/Frameworks/` с Team ID Q6L2SF6YDW, ShipIt на месте).

### Если клон не открывается

- **Хелперы падают при запуске, в отчётах о сбоях `Squirrel` и `different Team IDs`** (клон собран версией, которая
  удаляла ShipIt и переподписывала `Squirrel.framework`): пересоберите клон исправленной утилитой либо верните
  вендорский Squirrel и переподпишите внешний бандл (`<SHA1>` — `builder.signingIdentitySHA1` из `settings.json`,
  `<bundle id>` — id клона, для Claude 2nd `com.anthropic.claudefordesktop2`; клон должен быть закрыт). Ручная
  переподпись ниже — для сертификата из связки «Вход» (`signing-setup.sh`); если подпись создал сам ClaudeMultiAcc
  (отдельная связка), просто пересоберите клон:
  ```bash
  rm -rf "<clone>/Contents/Frameworks/Squirrel.framework"
  cp -Rc /Applications/Claude.app/Contents/Frameworks/Squirrel.framework "<clone>/Contents/Frameworks/"
  codesign -d --entitlements - --xml "<clone>/Contents/MacOS/Claude.real" > /tmp/ent.plist
  codesign --force --timestamp=none --sign <SHA1> --options runtime -i <bundle id> --entitlements /tmp/ent.plist "<clone>"
  ```
  Затем `cmacc instance verify "<clone>"` должен показать `PASS vendor-frameworks-intact`.

## Откат

```bash
cmacc instance rollback second "<путь бэкапа из строки Rollback:>"
```

Откат требует закрытого Claude 2nd. Текущая сборка переносится в `backup/failed-<дата-время>/` (её `Info.plist`
отключается). У бэкапа `Info.plist.disabled` снова становится `Info.plist`, бэкап возвращается в
`/Applications/Claude 2nd.app`, выполняется `lsregister -f`. Профиль не трогается ни при `--apply`, ни при откате.
После отката Claude 2nd снова работает на старой сборке со всеми её дефектами. Если восстановлен бэкап `legacy-…`,
откат сам возвращает у `second` в `instances.json` `builtBy: "legacy-script"` и убирает `pendingBuild`, поэтому
UpdateWatcher снова не трогает клон. После отката обычного бэкапа (без префикса) `builtBy` не меняется.

## После

- Уберите `build-2nd.sh` и `launcher-2nd.sh` из `~/Library/Application Support/ClaudeProfiles/` в архив (например,
  `ClaudeProfiles/archive/`). Не удаляйте их и больше не запускайте.
- `reapply-icons.sh` больше не нужен: бейдж «2nd» вшивается в иконку клона при каждой сборке — и при `--apply`, и при
  каждой пересборке UpdateWatcher-ом. Сменить надпись: «Изменить…» в меню ClaudeMultiAcc. Бейдж «Main» на
  официальном Claude утилита не ставит: официальное приложение она не трогает.
- Мусорный `Plain.app` во временной папке старой сессии (зарегистрирован как `com.anthropic.claudefordesktop`
  2.2553.13 и претендует на `claude:`) убирается командой `lsregister -u <путь>` с последующим удалением папки.
  Делайте это только сознательно и с согласия владельца машины.
- Теперь Claude 2nd собран ClaudeMultiAcc (`builtBy: "cmacc"`). UpdateWatcher будет пересобирать его вперёд по
  версиям после каждого обновления официального Claude. Если клон в этот момент открыт, готовая сборка ждёт
  (`pendingBuild`) и ставится через несколько секунд после того, как вы его закроете, или сразу по кнопке «Обновить»
  в меню (клон перезапустится после подтверждения). Решения записываются в
  `~/Library/Logs/ClaudeMultiAcc/updates.log`. Выключить автопересборку: `settings.json` →
  `"updates": {"autoRebuild": false}`.
