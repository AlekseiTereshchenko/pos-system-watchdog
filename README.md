# План: Проблема №1 — Регламентные задания без запущенного клиента 1С

## Context

Кассовая система (POS) на базе React + 1С Розница с файловой базой. Каждая торговая точка — отдельный Windows-сервер (IIS + файловая база 1С + веб-сборка). До 5 клиентов на точку. Центральный сервер с Kafka.

**Проблема:** Файловая база 1С не выполняет регламентные задания без запущенного клиента. Сейчас — ручной запуск каждое утро. Переход на клиент-серверную архитектуру 1С слишком дорог.

**Критичные регламентные задания:**
1. Фискализация чеков (каждые 10 сек) — через ПодключитьОбработчикОжидания в клиенте 1С → драйвер АТОЛ → ККТ. Работает ТОЛЬКО в клиентском контексте.
2. Актуализация цен/остатков/НСИ (каждые 5-15 мин)
3. Выгрузка в Kafka (каждую минуту), загрузка заказов (каждые 5 мин) — пересекаются, нужна параллельность

**Ограничения:** Нельзя менять React и код конфигурации 1С (но можно добавлять HTTP-сервисы в расширение). Форма фискализации открывается автоматически при запуске клиента 1С.

---

## Решение: Watchdog + HTTP-планировщик на PowerShell

### Архитектура

```
┌──────────────────────────────────────────────────────────┐
│               Windows Server (точка)                      │
│                                                          │
│  ┌─────────────────────┐   ┌──────────────────────────┐  │
│  │  pos-watchdog.ps1   │   │  pos-scheduler.ps1       │  │
│  │  (NSSM → Service)  │   │  (NSSM → Service)        │  │
│  │                     │   │                          │  │
│  │  • Мониторинг       │   │  • HTTP-запросы к 1С     │  │
│  │    процесса 1С      │   │    через IIS             │  │
│  │  • Health-check     │   │  • Параллельный запуск   │  │
│  │    очереди фискал.  │   │    заданий (RunspacePool)│  │
│  │  • Автозапуск       │   │  • Локальное расписание  │  │
│  │  • Перезапуск       │   │    из settings.json      │  │
│  │  • Telegram алерты  │   │  • Telegram алерты       │  │
│  └────────┬────────────┘   └──────────┬───────────────┘  │
│           │                           │                  │
│           ▼                           ▼                  │
│  ┌──────────────┐          ┌──────────────────────────┐  │
│  │ 1С Клиент    │          │ HTTP-сервисы 1С (IIS)    │  │
│  │ (1cv8.exe)   │          │ /sched/price-update      │  │
│  │ + Форма      │          │ /sched/stock-update      │  │
│  │   фискализ.  │          │ /sched/nsi-sync          │  │
│  │ + АТОЛ       │          │ /sched/kafka-export      │  │
│  └──────────────┘          │ /sched/orders-sync       │  │
│                            └──────────────────────────┘  │
│  ┌──────────────────────────────────────────────────┐    │
│  │  pos-health.ps1 (HTTP listener, порт 8095)       │    │
│  │  GET /health → JSON статус всех компонентов      │    │
│  └──────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────┘
```

**Почему HTTP, а не COM:**
- Параллельность: IIS обрабатывает запросы параллельно (пул приложений) — Kafka и заказы могут работать одновременно
- Уже работает: фронт React уже ходит в 1С через HTTP — механизм проверен
- Нет блокировок: COM к файловой базе плохо параллелится и блокирует базу для кассиров
- Проще: PowerShell HTTP-запрос (`Invoke-RestMethod`) проще и надёжнее COM Interop

**Что нужно в 1С (расширение):**
- Добавить HTTP-сервисы-обёртки, вызывающие ту же серверную логику, что и текущие регламентные задания
- Это не изменение конфигурации, а добавление в существующее расширение

### Структура проекта

```
project_pos_one/
├── src/
│   ├── pos-watchdog.ps1          # Watchdog: мониторинг + автозапуск клиента 1С
│   ├── pos-scheduler.ps1         # HTTP-планировщик регламентных заданий
│   ├── pos-health.ps1            # HTTP health endpoint
│   ├── lib/
│   │   ├── telegram.ps1          # Модуль отправки в Telegram
│   │   ├── onec-http.ps1         # Модуль HTTP-запросов к 1С
│   │   ├── config.ps1            # Загрузка и валидация конфига
│   │   └── logging.ps1           # Логирование (файл + Event Log)
│   └── config/
│       └── settings.json         # Конфигурация (пути, расписания, Telegram)
│
├── deploy/
│   ├── install.ps1               # Установка на точку (NSSM + службы)
│   ├── uninstall.ps1             # Удаление
│   ├── update.ps1                # Обновление скриптов
│   └── nssm.exe                  # NSSM для регистрации PS-скриптов как служб
│
└── tests/
    ├── test-http-endpoints.ps1   # Тест HTTP-эндпоинтов 1С
    ├── test-watchdog.ps1         # Тест логики watchdog
    └── test-telegram.ps1         # Тест отправки в Telegram
```

---

## Компоненты

### 1. pos-watchdog.ps1 — Watchdog клиента 1С

**Цель:** Гарантировать что клиент 1С запущен и форма фискализации работает.

**Главный цикл (каждые 10 сек):**
```
1. Проверить процесс 1cv8.exe жив?
   ├─ НЕТ → Запустить 1С клиент, ждать до 120 сек
   │         Если не запустился за 3 попытки → Telegram CRITICAL
   │
   └─ ДА → Проверить здоровье фискализации:
            - HTTP-запрос к 1С: GET /sched/fiscal-status
              (возвращает кол-во чеков в очереди и возраст старейшего)
            - Если очередь растёт / чеки зависли > 2 мин → счётчик unhealthy++
            - Если 3 подряд unhealthy → перезапустить клиент 1С
            - Если 5 перезапусков за час → Telegram CRITICAL, стоп перезапусков
```

**Запуск клиента 1С:**
```powershell
Start-Process -FilePath $OneCExe -ArgumentList "ENTERPRISE /F`"$BasePath`" /N`"$User`" /P`"$Password`""
# Форма фискализации открывается автоматически (настроено в конфигурации 1С)
```

**Остановка (для перезапуска):**
```
1. Попытка штатного закрытия (WM_CLOSE) → ждать 15 сек
2. Если не закрылся → Stop-Process -Force
3. Ждать 5 сек (освобождение файлов базы)
4. Проверить что .lck файл не заблокирован
```

### 2. pos-scheduler.ps1 — HTTP-планировщик

**Цель:** Выполнять регламентные задания через HTTP-запросы к 1С. Поддерживать параллельный запуск.

**Механизм:**
```powershell
# Каждое задание — HTTP POST к эндпоинту 1С через IIS
Invoke-RestMethod -Uri "http://localhost/retail/hs/sched/kafka-export" -Method POST -TimeoutSec 180

# Параллельный запуск через PowerShell RunspacePool (или Start-Job)
# Kafka каждую минуту и загрузка заказов каждые 5 мин работают одновременно
# IIS обрабатывает параллельно — так же как запросы от 5 касс
```

**Расписание задач (из settings.json):**

| Задача | Интервал | Таймаут | HTTP endpoint |
|--------|----------|---------|---------------|
| Выгрузка в Kafka | 1 мин | 50 сек | POST /sched/kafka-export |
| Загрузка заказов | 5 мин | 3 мин | POST /sched/orders-sync |
| Актуализация цен | 5 мин | 3 мин | POST /sched/price-update |
| Актуализация остатков | 5 мин | 3 мин | POST /sched/stock-update |
| Синхронизация НСИ | 30 мин | 10 мин | POST /sched/nsi-sync |

**Правила:**
- Задания запускаются параллельно (каждое в своём runspace)
- Если предыдущий запуск задания ещё не завершён — новый пропускается
- При ошибке — retry через 1 мин, макс 3 попытки, потом Telegram WARNING
- Таймаут на каждый запрос — из конфига
- Логирование: время старта, результат, длительность каждого задания

**Расписание — локальное (MVP):**
- Хранится в settings.json на точке
- Планировщик подхватывает изменения при перезапуске
- В будущем (проблема №3): централизованное управление расписанием

### 3. pos-health.ps1 — HTTP health endpoint

**Цель:** Предоставить HTTP API для мониторинга.

**GET :8095/health →**
```json
{
  "storeId": "STORE-001",
  "timestamp": "2026-04-23T10:15:30Z",
  "overall": "healthy",
  "oneCClient": {
    "status": "running",
    "pid": 12345,
    "uptime": "04:23:15",
    "restartsToday": 1
  },
  "fiscalQueue": {
    "pendingReceipts": 0,
    "oldestPendingAge": null
  },
  "scheduler": {
    "KafkaExport": { "lastRun": "...", "duration": "3s", "result": "success" },
    "OrdersSync": { "lastRun": "...", "duration": "12s", "result": "success" },
    "PriceUpdate": { "lastRun": "...", "duration": "5s", "result": "error", "error": "timeout" }
  }
}
```

Реализация через `System.Net.HttpListener` в PowerShell.

### 4. HTTP-сервисы в расширении 1С

**Что добавить в расширение (не в конфигурацию):**

HTTP-сервис `Scheduler` с методами:
- `POST /sched/kafka-export` — вызывает серверную процедуру формирования сообщений Kafka
- `POST /sched/orders-sync` — вызывает серверную процедуру загрузки заказов
- `POST /sched/price-update` — вызывает серверную процедуру актуализации цен
- `POST /sched/stock-update` — вызывает серверную процедуру актуализации остатков
- `POST /sched/nsi-sync` — вызывает серверную процедуру синхронизации НСИ
- `GET /sched/fiscal-status` — возвращает состояние очереди фискализации (для health-check watchdog)

Каждый обработчик — обёртка в 5-10 строк: вызов существующей серверной логики + возврат JSON-результата.

### 5. Конфигурация (settings.json)

```json
{
  "storeId": "STORE-001",
  "oneC": {
    "exePath": "C:\\Program Files\\1cv8\\8.3.xx.xxxx\\bin\\1cv8.exe",
    "basePath": "C:\\Base1C\\Retail",
    "clientUser": "КассирАвто",
    "clientPassword": "...",
    "httpBaseUrl": "http://localhost/retail/hs"
  },
  "watchdog": {
    "checkIntervalSec": 10,
    "unhealthyThreshold": 3,
    "maxRestartsPerHour": 5,
    "processStartTimeoutSec": 120,
    "fiscalQueueStaleMins": 2
  },
  "scheduler": {
    "tasks": [
      { "name": "KafkaExport", "endpoint": "/sched/kafka-export", "intervalSec": 60, "timeoutSec": 50 },
      { "name": "OrdersSync", "endpoint": "/sched/orders-sync", "intervalSec": 300, "timeoutSec": 180 },
      { "name": "PriceUpdate", "endpoint": "/sched/price-update", "intervalSec": 300, "timeoutSec": 180 },
      { "name": "StockUpdate", "endpoint": "/sched/stock-update", "intervalSec": 300, "timeoutSec": 180 },
      { "name": "NsiSync", "endpoint": "/sched/nsi-sync", "intervalSec": 1800, "timeoutSec": 600 }
    ]
  },
  "health": {
    "port": 8095
  },
  "telegram": {
    "botToken": "...",
    "chatId": "..."
  },
  "logging": {
    "path": "C:\\PosLogs",
    "maxFileSizeMB": 10,
    "retentionDays": 30
  }
}
```

---

## Деплой

### Установка (install.ps1)
1. Копировать файлы в `C:\PosServices\`
2. Положить NSSM в `C:\PosServices\nssm.exe`
3. Зарегистрировать службы:
   ```
   nssm install PosWatchdog powershell.exe -ExecutionPolicy Bypass -File C:\PosServices\pos-watchdog.ps1
   nssm set PosWatchdog Start SERVICE_AUTO_START
   nssm install PosScheduler powershell.exe -ExecutionPolicy Bypass -File C:\PosServices\pos-scheduler.ps1
   nssm set PosScheduler Start SERVICE_AUTO_START
   nssm install PosHealthMonitor powershell.exe -ExecutionPolicy Bypass -File C:\PosServices\pos-health.ps1
   nssm set PosHealthMonitor Start SERVICE_AUTO_START
   ```
4. Настроить автологон Windows (нужна десктоп-сессия для АТОЛ)
5. Открыть порт 8095 в файрволле
6. Заполнить settings.json для точки
7. Опубликовать HTTP-сервисы расширения 1С через IIS
8. Запустить службы
9. Проверить /health

### Раскатка
- Неделя 1: пилотная точка, ежедневный мониторинг, тюнинг порогов
- Неделя 2-3: доработка по результатам
- Неделя 4+: раскатка по 1-2 точки в день

---

## Риски

| Риск | Митигация |
|------|-----------|
| IIS перегружен параллельными запросами (от касс + от планировщика) | Ограничить параллельность планировщика (макс 2-3 одновременных задания). Мониторить время ответа IIS. |
| 1С клиент зависает (не падает, но не работает) | Health-check очереди фискализации через HTTP /sched/fiscal-status |
| Перезапуск во время пробития чека | Перезапуск только если очередь стоит > 2 мин |
| АТОЛ драйвер зависает | Детектим по растущей очереди → алерт (решение ручное) |
| IIS/веб-публикация 1С упала | Watchdog проверяет доступность HTTP — если 1С HTTP не отвечает, алерт |
| HTTP-эндпоинт задания выполняется слишком долго | Таймаут из конфига, при превышении — отмена + алерт |
| 5+ перезапусков за час | Стоп перезапусков + CRITICAL алерт → ручное вмешательство |

---

## Последовательность разработки

| Этап | Что | Дни |
|------|-----|-----|
| 1 | lib/ — logging, config, telegram, onec-http | 1-2 |
| 2 | HTTP-сервисы в расширении 1С (обёртки) | 1-2 |
| 3 | pos-scheduler.ps1 + параллельный запуск + тесты | 2-3 |
| 4 | pos-watchdog.ps1 + health-check логика | 2-3 |
| 5 | pos-health.ps1 (HTTP endpoint) | 1 |
| 6 | deploy/ — install, update, uninstall | 1-2 |
| 7 | tests/ + пилот на одной точке | 2-3 |
| **Итого** | | **10-16 дней** |

---

## Верификация

1. **Тест HTTP-эндпоинтов 1С:** `test-http-endpoints.ps1` — вызов каждого /sched/ эндпоинта, проверка ответа
2. **Тест параллельности:** запустить Kafka + заказы одновременно, убедиться что оба отрабатывают
3. **Тест Watchdog:** убить процесс 1С → watchdog должен перезапустить за 2 мин
4. **Тест Health:** GET /health возвращает корректный JSON со всеми компонентами
5. **Тест Telegram:** получить алерт при имитации CRITICAL
6. **Тест полного цикла:** остановить клиент 1С, положить чек в очередь, убедиться что watchdog перезапустил клиент и чек фискализирован
