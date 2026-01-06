# runcore

`runcore` — это `lxmd`-совместимый (по конфигу/поведению) LXMF daemon, который поднимает Reticulum внутри процесса (без отдельного `rnsd`).

## Быстрый старт

Запуск без параметров создаст `lxmd`-совместимую директорию конфига и дефолтный `config`.

```bash
go run ./cmd/runcore
```

Показать пример конфига и выйти:

```bash
go run ./cmd/runcore -exampleconfig
```

По умолчанию Reticulum-конфиг создаётся в `<configdir>/rns/config` из встроенного шаблона (один раз; дальше файл можно править руками). Чтобы перегенерировать LXMF transient state (ratchets), используй `-reset-lxmf`.

## Использование как библиотеки

Минимальный пример:

```go
cfgDir := "/path/to/AppSupport/runcore"
_, _ = runcore.EnsureLXMDConfig(cfgDir)
_, _ = runcore.EnsureRNSConfig(cfgDir, 4)

n, err := runcore.Start(runcore.Options{Dir: cfgDir})
if err != nil { panic(err) }
defer n.Close()

n.SetInboundHandler(func(m *lxmf.LXMessage) {
	// m.TitleAsString(), m.ContentAsString(), m.SourceHash, ...
})
```

Управление конфигом (посмотреть/изменить/сохранить/сбросить дефолтный):

- Загрузить: `runcore.LoadLXMDConfig(cfgDir)`
- Сохранить: `runcore.SaveLXMDConfig(cfg, cfgDir)`
- Сбросить: `runcore.ResetLXMDConfig(cfgDir)`

Reticulum config:

- Создать если нет: `runcore.EnsureRNSConfig(cfgDir, logLevel)`
- Сбросить: `runcore.ResetRNSConfig(cfgDir, logLevel)`

## Два экземпляра

Reticulum в `go-reticulum` — singleton, поэтому два узла надо запускать двумя процессами с разными `-config` директориями:

```bash
go run ./cmd/runcore -config .nodeA -reset-lxmf -v
go run ./cmd/runcore -config .nodeB -reset-lxmf -v
```
