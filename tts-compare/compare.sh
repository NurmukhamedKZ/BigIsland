#!/bin/bash
# Сравнение TTS-моделей OpenRouter на одном русском тексте.
# Запуск: OPENROUTER_API_KEY=... [ONLY=gemini] ./compare.sh [файл_с_текстом]
# Результат: out/<модель>.mp3 + таблица времени и размера.
set -u
cd "$(dirname "$0")"
: "${OPENROUTER_API_KEY:?Задай OPENROUTER_API_KEY}"

# Текст с подвохами: числа, даты, сокращения, английские слова, ударения.
TEXT_DEFAULT='Привет! Это проверка озвучки. В 2026 году, 17 сентября, я прочитал 3 главы книги — примерно 45 страниц, т.е. около 12 %. Замок на двери сломался, поэтому пришлось идти в старинный замок пешком. Мой MacBook Pro работает на чипе M4, а приложение BigIsland написано на Swift. «Никогда не сдавайся», — сказал он и улыбнулся.'
TEXT=$(if [ $# -ge 1 ]; then cat "$1"; else printf '%s' "$TEXT_DEFAULT"; fi)

# модель|голос|формат (пустой голос — не передаём; pcm — Gemini умеет только его)
MODELS='google/gemini-3.1-flash-tts-preview|Kore|pcm
qwen/qwen-audio-3.0-tts-flash|loongjohn|mp3
qwen/qwen-audio-3.0-tts-plus|longanlufeng|mp3
fish-audio/s2.1-pro-free:free||mp3
microsoft/mai-voice-2-flash|en-US-Harper:MAI-Voice-2|mp3
x-ai/grok-voice-tts-1.0|eve|mp3'

mkdir -p out
printf '%-40s %8s %8s %8s\n' MODEL FIRST_B TOTAL SIZE
echo "$MODELS" | grep -- "${ONLY:-}" | while IFS='|' read -r model voice fmt; do
  name=$(echo "$model" | tr '/:' '__')
  body=$(TEXT="$TEXT" MODEL="$model" VOICE="$voice" FMT="$fmt" python3 -c '
import json, os
b = {"model": os.environ["MODEL"], "input": os.environ["TEXT"], "response_format": os.environ["FMT"]}
if os.environ["VOICE"]: b["voice"] = os.environ["VOICE"]
print(json.dumps(b, ensure_ascii=False))')
  stats=$(curl -s -o "out/$name.$fmt" -w '%{http_code} %{time_starttransfer} %{time_total} %{size_download}' \
    https://openrouter.ai/api/v1/audio/speech \
    -H "Authorization: Bearer $OPENROUTER_API_KEY" \
    -H 'Content-Type: application/json' \
    --data-binary "$body")
  read -r code first total size <<< "$stats"
  if [ "$code" = 200 ]; then
    if [ "$fmt" = pcm ]; then
      # Gemini: сырой PCM 24 кГц, 16 бит, моно → wav
      python3 -c 'import sys, wave
w = wave.open(sys.argv[1][:-3] + "wav", "wb"); w.setnchannels(1); w.setsampwidth(2); w.setframerate(24000)
w.writeframes(open(sys.argv[1], "rb").read()); w.close()' "out/$name.pcm" && rm "out/$name.pcm"
    fi
    printf '%-40s %7.2fs %7.2fs %7dK\n' "$model" "$first" "$total" $((size / 1024))
  else
    printf '%-40s ОШИБКА %s: %s\n' "$model" "$code" "$(head -c 300 "out/$name.$fmt")"
    rm -f "out/$name.$fmt"
  fi
done

echo; echo "Слушать: open $(pwd)/out"
