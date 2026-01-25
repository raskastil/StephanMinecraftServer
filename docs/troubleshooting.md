# Troubleshooting

## /sk не работает, команда не найдена
Проблема в том, что в этой папке сервера (`C:\Users\Artem Vekshin\StephanMinecraftServer-`) не было плагина **Skript**, поэтому команды `/sk` не существует.

### Что сделано
Скопирован `Skript-2.12.2.jar` в:
`C:\Users\Artem Vekshin\StephanMinecraftServer-\plugins\`

### Что дальше
1) Перезапусти сервер (обязательно).
2) В игре или консоли:
```
/sk reload coins
```
или
```
/skript reload coins
```

Если снова не работает — проверь логи старта сервера, там будет ошибка загрузки Skript.
