# Додавання нового backup item у Backrest

Цей документ описує стандартний процес додавання нового сервісу до off-site backup у Backblaze B2 через Backrest/Restic.

Приклад backup item:

```text
app-navidrome
```

Загальна схема:

```text
Сервіс
  → локальний підготовлений backup у /mnt/backup
  → Backrest / Restic
  → Backblaze B2
```

> Backrest повинен копіювати підготовлені й узгоджені backup-файли сервісу, а не активну базу даних або Docker volume під час їх використання.

---

## 1. Стандарт іменування

Для одного backup item бажано використовувати однаковий ідентифікатор у всіх компонентах.

Для Navidrome:

```text
Backup item ID:
app-navidrome

Local path:
/mnt/backup/services/app-navidrome

Backrest repository ID:
backblaze-services-app-navidrome

Backblaze prefix:
app-navidrome

Backrest plan ID:
app-navidrome
```

Рекомендований формат:

```text
app-<service-name>
```

Приклади:

```text
app-navidrome
app-gitea
app-n8n
app-home-assistant
```

---

## 2. Backblaze bucket

Відкрити сторінку керування bucket:

```text
https://secure.backblaze.com/b2_buckets.htm
```

Для backup сервісів використовується спільний bucket:

```text
shshx-homelab-services
```

Якщо bucket уже існує, створювати окремий bucket для кожного сервісу не потрібно.

Кожен сервіс зберігається у власному prefix:

```text
shshx-homelab-services/
├── app-navidrome/
├── app-gitea/
├── app-n8n/
└── app-home-assistant/
```

Для Navidrome використовується prefix:

```text
app-navidrome
```

Повний URI Restic repository:

```text
s3:https://s3.eu-central-003.backblazeb2.com/shshx-homelab-services/app-navidrome
```

---

## 3. Backblaze Application Key

Відкрити:

```text
Backblaze → Application Keys → Add a New Application Key
```

Параметри ключа:

```text
Name:
backrest-002-rw-services

Allow access to Bucket:
shshx-homelab-services

Type of Access:
Read and Write
```

Увімкнути:

```text
Allow listing all bucket names including bucket creation dates
(required for S3 List Buckets API)
```

### Політика використання ключів

Один Application Key можна використовувати для кількох Restic repositories у межах bucket:

```text
shshx-homelab-services
```

Тобто окремий Application Key для кожного сервісу не є обов’язковим.

Окремий ключ на сервіс доцільний лише тоді, коли потрібні:

- незалежна ротація credentials;
- жорсткіша ізоляція;
- окремі права доступу;
- окремий аудит використання ключів.

---

## 4. Збереження Backblaze credentials у KeePass

Рекомендований формат назв записів:

```text
API | <система> | <призначення> | <scope> | <рівень доступу>
```

Для цього ключа:

```text
API | Backblaze B2 | Backrest | services | RW
```

### Основні поля KeePass

```text
Title:
API | Backblaze B2 | Backrest | services | RW

Username:
<keyID>

Password:
<applicationKey>
```

### Додаткові поля

```text
keyID
keyName
bucketName
s3Endpoint
```

Приклад значень:

```text
keyName:
backrest-002-rw-services

bucketName:
shshx-homelab-services

s3Endpoint:
s3.eu-central-003.backblazeb2.com
```

Поле `Password` використовується для `applicationKey`, тому дублювати його в окремому полі зазвичай не потрібно.

> `applicationKey` відображається Backblaze лише під час створення ключа. Його потрібно одразу зберегти в KeePass.

---

## 5. Створення Restic repository у Backrest

У Backrest відкрити:

```text
Repositories → Add Repository
```

### Repository ID

```text
backblaze-services-app-navidrome
```

Рекомендований формат:

```text
<backend>-<bucket-purpose>-<backup-item>
```

Приклади:

```text
backblaze-services-app-navidrome
backblaze-services-app-gitea
backblaze-services-app-n8n
```

### Repository URI

```text
s3:https://s3.eu-central-003.backblazeb2.com/shshx-homelab-services/app-navidrome
```

Загальний формат:

```text
s3:https://<S3-endpoint>/<bucket>/<repository-prefix>
```

### Environment variables

Додати:

```text
AWS_ACCESS_KEY_ID=<keyID>
AWS_SECRET_ACCESS_KEY=<applicationKey>
```

Значення беруться із KeePass-запису:

```text
API | Backblaze B2 | Backrest | services | RW
```

---

## 6. Шифрувальний пароль Restic repository

Для кожного Restic repository створюється окремий пароль шифрування.

Згенерувати пароль:

```bash
openssl rand -base64 48
```

Рекомендований KeePass-запис:

```text
ENC | Restic | backblaze-services-app-navidrome
```

### Поля KeePass

```text
Title:
ENC | Restic | backblaze-services-app-navidrome

Password:
<Restic repository password>

repositoryId:
backblaze-services-app-navidrome

repositoryUri:
s3:https://s3.eu-central-003.backblazeb2.com/shshx-homelab-services/app-navidrome
```

> Restic repository password не є Backblaze API key. Без нього неможливо розшифрувати й відновити backup.

Після введення Repository URI, environment variables і encryption password:

1. виконати тест конфігурації;
2. якщо тест успішний — ініціалізувати repository;
3. зберегти конфігурацію.

---

## 7. Локальна структура backup item

Рекомендована структура:

```text
/mnt/backup/
├── app-navidrome/
│   ├── data/
│   ├── navidrome.db
│   └── backup-metadata.json
├── app-gitea/
├── app-n8n/
└── nextcloud-aio/
    └── borg/
```

Кожен backup item повинен мати власний каталог:

```text
/mnt/backup/<backup-item-id>
```

Для Navidrome:

```text
/mnt/backup/app-navidrome
```

Перед налаштуванням Backrest перевірити фактичну структуру:

```bash
find /mnt/backup/app-navidrome -maxdepth 4 -printf '%y %p\n'
```

---

## 8. Перевірка джерела через hook

Перед створенням snapshot Backrest повинен перевірити:

- що `/mnt/backup` є змонтованою файловою системою;
- що каталог backup item існує;
- що присутній основний backup-файл;
- що відсутня ситуація, коли Backrest читає порожній локальний каталог замість змонтованого NAS.

### Налаштування hook

```text
Hook:
CONDITION_SNAPSHOT_START

Error Behavior:
ON_ERROR_FATAL
```

### Приклад hook для Navidrome

Якщо структура має вигляд:

```text
/mnt/backup/app-navidrome/
├── data/
└── navidrome.db
```

використовувати:

```sh
/bin/sh -c '
mountpoint -q /mnt/backup &&
test -d /mnt/backup/app-navidrome/data &&
test -f /mnt/backup/app-navidrome/navidrome.db
'
```

Однорядковий варіант для Backrest UI:

```sh
/bin/sh -c 'mountpoint -q /mnt/backup && test -d /mnt/backup/app-navidrome/data && test -f /mnt/backup/app-navidrome/navidrome.db'
```

Після додавання hook:

1. натиснути `Test`;
2. переконатися, що перевірка завершилася успішно;
3. натиснути `Submit`.

---

## 9. Перевірка правильності шляхів

Не можна змішувати каталоги різних backup items.

Неправильно:

```sh
test -d /mnt/backup/app-navidrome/data &&
test -f /mnt/backup/nextcloud-aio/data/navidrome.db
```

У цьому прикладі перша перевірка стосується `app-navidrome`, а друга — `nextcloud-aio`.

Правильно:

```sh
test -d /mnt/backup/app-navidrome/data &&
test -f /mnt/backup/app-navidrome/navidrome.db
```

Усі перевірки одного hook повинні стосуватися одного backup item.

---


---

## 10. Створення Plan у Backrest

Після успішного створення та перевірки Restic repository потрібно створити Plan, який визначає джерело backup, розклад запуску, retention policy та hooks.

У Backrest відкрити:

```text
Plans → Add Plan
```

### Plan name

```text
app-navidrome
```

Рекомендовано використовувати той самий ідентифікатор, що й для backup item:

```text
app-<service-name>
```

### Repository

Вибрати:

```text
backblaze-services-app-navidrome
```

### Backup scope

Додати scope типу `Path`:

```text
/mnt/backup/services/app-navidrome
```

Перед збереженням Plan перевірити, що каталог існує і містить очікувані backup-файли:

```bash
mountpoint -q /mnt/backup
test -d /mnt/backup/services/app-navidrome
find /mnt/backup/services/app-navidrome -maxdepth 3 -printf '%y %p\n'
```

> У Plan потрібно вказувати каталог підготовленого backup, а не активний Docker volume або робочу базу даних сервісу.

### Розклад

Cron expression:

```cron
0 4 * * *
```

Це означає запуск щодня о `04:00`.

Перед використанням розкладу перевірити часовий пояс Backrest LXC:

```bash
timedatectl
date
```

Очікуваний часовий пояс:

```text
Europe/Kyiv
```

Backrest повинен запускатися лише після завершення локального backup сервісу. Якщо локальний backup Navidrome також запускається близько `04:00`, потрібно перенести Backrest на пізніший час, наприклад:

```cron
0 5 * * *
```

### Retention policy

Встановити:

```text
Keep Daily:
7

Keep Weekly:
4

Keep Monthly:
6
```

Це зберігає:

- 7 щоденних snapshots;
- 4 щотижневі snapshots;
- 6 щомісячних snapshots.

Retention policy визначає, які snapshots залишаються після виконання операції `forget`. Фактичне звільнення невикористаних блоків у repository виконується операцією `prune`.

### Hook перевірки джерела

Додати hook:

```text
Hook:
CONDITION_SNAPSHOT_START

Error Behavior:
ON_ERROR_FATAL
```

Для структури:

```text
/mnt/backup/services/app-navidrome/
├── data/
└── navidrome.db
```

використати:

```sh
/bin/sh -c '
mountpoint -q /mnt/backup &&
test -d /mnt/backup/services/app-navidrome/data &&
test -f /mnt/backup/services/app-navidrome/navidrome.db
'
```

Однорядковий варіант для Backrest UI:

```sh
/bin/sh -c 'mountpoint -q /mnt/backup && test -d /mnt/backup/services/app-navidrome/data && test -f /mnt/backup/services/app-navidrome/navidrome.db'
```

Hook потрібно адаптувати до фактичної структури backup item. Перед збереженням:

1. натиснути `Test`;
2. переконатися, що hook завершується успішно;
3. натиснути `Submit`.

### Підсумкова конфігурація Plan

```text
Plan name:
app-navidrome

Repository:
backblaze-services-app-navidrome

Scope type:
Path

Path:
/mnt/backup/services/app-navidrome

Cron expression:
0 4 * * *

Retention:
Daily 7
Weekly 4
Monthly 6

Hook:
CONDITION_SNAPSHOT_START

Hook error behavior:
ON_ERROR_FATAL

Backrest plan:
app-navidrome

Plan scope:
/mnt/backup/services/app-navidrome

Plan schedule:
0 4 * * *

Retention:
Daily 7
Weekly 4
Monthly 6
```

### Перший запуск Plan

Після створення Plan виконати перший backup вручну:

```text
Run Backup Now
```

Перевірити:

- завершення зі статусом `Success`;
- кількість оброблених файлів;
- обсяг доданих даних;
- появу нового snapshot;
- відсутність помилок hook;
- появу Restic-даних у відповідному Backblaze prefix.

Після першого успішного запуску відновити щонайменше один файл у тестовий каталог:

```text
/tmp/restore-test
```

і порівняти його з оригіналом:

```bash
sha256sum \
  /mnt/backup/services/app-navidrome/navidrome.db \
  /tmp/restore-test/mnt/backup/services/app-navidrome/navidrome.db
```

Обидва SHA-256 хеші мають збігатися.


---

## 11. Перевірка готовності repository

Перед створенням Plan перевірити:

- repository успішно ініціалізований;
- Backrest має доступ до Backblaze B2;
- Backrest бачить локальний каталог;
- hook завершується успішно;
- шифрувальний пароль Restic збережений у KeePass;
- Backblaze Application Key збережений у KeePass;
- локальний backup item містить очікувані файли.

Корисні команди:

```bash
mountpoint /mnt/backup
ls -la /mnt/backup/app-navidrome
find /mnt/backup/app-navidrome -maxdepth 3 -type f
```

---

## 12. Секрети та Git

У Git-репозиторій не додаються:

```text
applicationKey
Restic repository password
KeePass exports
credentials files
секретні environment variables
```

У документації можна зберігати:

```text
keyName
bucketName
repository ID
repository URI
S3 endpoint
локальні шляхи
назви KeePass-записів
структуру backup item
hook scripts без секретів
```

---

## 13. Підсумкова конфігурація для Navidrome

```text
Backup item ID:
app-navidrome

Local path:
/mnt/backup/services/app-navidrome

Backblaze bucket:
shshx-homelab-services

Backblaze prefix:
app-navidrome

Backrest repository ID:
backblaze-services-app-navidrome

Repository URI:
s3:https://s3.eu-central-003.backblazeb2.com/shshx-homelab-services/app-navidrome

KeePass API entry:
API | Backblaze B2 | Backrest | services | RW

KeePass encryption entry:
ENC | Restic | backblaze-services-app-navidrome

Hook:
CONDITION_SNAPSHOT_START

Hook error behavior:
ON_ERROR_FATAL

Backrest plan:
app-navidrome

Plan scope:
/mnt/backup/services/app-navidrome

Plan schedule:
0 4 * * *

Retention:
Daily 7
Weekly 4
Monthly 6
```
