#!/usr/bin/env bash
set -euo pipefail

REQUIRED_BRANCH="feature/ai-irrigation-dev"
EXPECTED_REMOTE_PREFIX="https://github.com/"

echo "🔍 [OpenCode Git Checker] Запуск проверки..."

# 1. Проверка ветки
CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "detached")
if [[ "$CURRENT_BRANCH" != "$REQUIRED_BRANCH" ]]; then
    echo "❌ Неверная ветка: $CURRENT_BRANCH"
    echo "💡 Исправление: git switch $REQUIRED_BRANCH"
    exit 1
fi
echo "✅ Ветка: $CURRENT_BRANCH"

# 2. Проверка remote URL
REMOTE_URL=$(git remote get-url origin 2>/dev/null || echo "")
if [[ ! "$REMOTE_URL" =~ ^$EXPECTED_REMOTE_PREFIX ]]; then
    echo "❌ Remote origin не использует HTTPS (текущий: $REMOTE_URL)"
    exit 1
fi
echo "✅ Remote: HTTPS настроен"

# 3. Проверка токена (чтение репо)
if ! git ls-remote --exit-code origin >/dev/null 2>&1; then
    echo "❌ Ошибка аутентификации. Проверьте PAT в ~/.git-credentials"
    echo "💡 Требуемые права: Contents → Read and write"
    exit 1
fi
echo "✅ PAT валиден, доступ к репозиторию подтверждён"

# 4. Проверка прав на запись (dry-run)
if git push --dry-run origin HEAD >/dev/null 2>&1; then
    echo "✅ Права на запись подтверждены"
else
    echo "⚠️ Dry-run push не прошёл (возможно, нет upstream или ветка новая)"
    echo "💡 Первый git push создаст ветку автоматически"
fi

echo "🎉 Все проверки пройдены. OpenCode готов к работе."
exit 0
