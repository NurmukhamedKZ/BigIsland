#!/bin/bash
# Сравнение TTS-моделей OpenRouter на одном русском тексте.
# Запуск: OPENROUTER_API_KEY=... ./compare.sh [файл_с_текстом]
# Результат: out/<модель>.mp3 + таблица времени и размера.
set -u
cd "$(dirname "$0")"
: "${OPENROUTER_API_KEY:?Задай OPENROUTER_API_KEY}"

# Текст с подвохами: числа, даты, сокращения, английские слова, ударения.
TEXT_DEFAULT='Привет! Это проверка озвучки. В 2026 году, 17 сентября, я прочитал 3 главы книги — примерно 45 страниц, т.е. около 12 %. Замок на двери сломался, поэтому пришлось идти в старинный замок пешком. Мой MacBook Pro работает на чипе M4, а приложение BigIsland написано на Swift. «Никогда не сдавайся», — сказал он и улыбнулся.'
TEXT=$(if [ $# -ge 1 ]; then cat "$1"; else printf '%s' "$TEXT_DEFAULT"; fi)

# модель|голос (пустой голос — не передаём, у провайдера свой по умолчанию)
MODELS='google/gemini-3.1-flash-tts-preview|Kore
qwen/qwen-audio-3.0-tts-flash|loongjohn
qwen/qwen-audio-3.0-tts-plus|longanlufeng
fish-audio/s2.1-pro-free:free|
microsoft/mai-voice-2-flash|en-US-Harper:MAI-Voice-2
x-ai/grok-voice-tts-1.0|eve'

mkdir -p out
printf '%-40s %8s %8s %8s\n' MODEL FIRST_B TOTAL SIZE
echo "$MODELS" | while IFS='|' read -r model voice; do
  name=$(echo "$model" | tr '/:' '__')
  body=$(TEXT="$TEXT" MODEL="$model" VOICE="$voice" python3 -c '
import json, os
b = {"model": os.environ["MODEL"], "input": os.environ["TEXT"], "response_format": "mp3"}
if os.environ["VOICE"]: b["voice"] = os.environ["VOICE"]
print(json.dumps(b, ensure_ascii=False))')
  stats=$(curl -s -o "out/$name.mp3" -w '%{http_code} %{time_starttransfer} %{time_total} %{size_download}' \
    https://openrouter.ai/api/v1/audio/speech \
    -H "Authorization: Bearer $OPENROUTER_API_KEY" \
    -H 'Content-Type: application/json' \
    --data-binary "$body")
  read -r code first total size <<< "$stats"
  if [ "$code" = 200 ]; then
    printf '%-40s %7.2fs %7.2fs %7dK\n' "$model" "$first" "$total" $((size / 1024))
  else
    printf '%-40s ОШИБКА %s: %s\n' "$model" "$code" "$(head -c 300 "out/$name.mp3")"
    rm -f "out/$name.mp3"
  fi
done

echo; echo "Слушать: open $(pwd)/out"
