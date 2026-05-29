#!/bin/bash

# ============================================
# ЕДИНЫЙ СКРИПТ ДЛЯ РАБОТЫ С МЕДЛЕННЫМИ ЗОНАМИ
# Версия 6.0 - автоматическая настройка при первом запуске
# ============================================

VERSION="6.0"

# Получаем директорию скрипта
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/disk_fix_config.conf"
ZONES_FILE="$SCRIPT_DIR/slow_zones.txt"
LOG_FILE="$SCRIPT_DIR/disk_fix.log"

# === НАСТРОЙКИ ПО УМОЛЧАНИЮ ===
DEFAULT_DISK="/dev/sda"
DEFAULT_PARTITION="/dev/sda1"
DEFAULT_MOUNT="/media/ubuntu/5d0806c8-77ac-4c6e-af58-52a22f6e506a"
DEFAULT_MIN_SPEED=20
DEFAULT_BEFORE_MB=100
DEFAULT_AFTER_MB=400
DEFAULT_WAIT_SEC=5
DEFAULT_BLOCK_SIZE_MB=10

# === ТЕКУЩИЕ НАСТРОЙКИ ===
DISK=""
PARTITION=""
TARGET_MOUNT=""
MIN_SPEED=""
BEFORE_MB=""
AFTER_MB=""
WAIT_SEC=""
BLOCK_SIZE_MB=""

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Функции вывода
print_status() { echo -e "${GREEN}[✓]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_info() { echo -e "${BLUE}[i]${NC} $1"; }
print_header() {
    echo ""
    echo "=========================================="
    echo -e "${BLUE}$1${NC}"
    echo "=========================================="
}

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Функция загрузки настроек
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        print_status "Настройки загружены из $CONFIG_FILE"
        return 0
    else
        print_warning "Файл настроек не найден. Будет запущена интерактивная настройка."
        DISK="$DEFAULT_DISK"
        PARTITION="$DEFAULT_PARTITION"
        TARGET_MOUNT="$DEFAULT_MOUNT"
        MIN_SPEED="$DEFAULT_MIN_SPEED"
        BEFORE_MB="$DEFAULT_BEFORE_MB"
        AFTER_MB="$DEFAULT_AFTER_MB"
        WAIT_SEC="$DEFAULT_WAIT_SEC"
        BLOCK_SIZE_MB="$DEFAULT_BLOCK_SIZE_MB"
        return 1
    fi
}

# Функция сохранения настроек
save_config() {
    cat > "$CONFIG_FILE" << EOF
# Конфигурационный файл
# Создан $(date)

DISK="$DISK"
PARTITION="$PARTITION"
TARGET_MOUNT="$TARGET_MOUNT"
MIN_SPEED="$MIN_SPEED"
BEFORE_MB="$BEFORE_MB"
AFTER_MB="$AFTER_MB"
WAIT_SEC="$WAIT_SEC"
BLOCK_SIZE_MB="$BLOCK_SIZE_MB"
EOF
    print_status "Настройки сохранены в $CONFIG_FILE"
    log_message "Настройки сохранены"
}

# Функция проверки зависимостей
check_dependencies() {
    local missing=()
    
    if ! command -v bc &> /dev/null; then
        missing+=("bc")
    fi
    
    if [ ${#missing[@]} -ne 0 ]; then
        print_error "Отсутствуют необходимые утилиты: ${missing[*]}"
        echo "Установите: sudo apt install ${missing[*]}"
        return 1
    fi
    
    return 0
}

# Функция проверки прав root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "Запустите скрипт с правами sudo"
        exit 1
    fi
}

# Функция добавления зоны
add_zone() {
    local seek=$1
    local count=$2
    
    if grep -q "^$seek|$count$" "$ZONES_FILE" 2>/dev/null; then
        return 1
    fi
    
    echo "$seek|$count" >> "$ZONES_FILE"
    log_message "Добавлена зона: seek=$seek, count=$count"
    return 0
}

# Функция получения количества зон
get_zones_count() {
    if [ ! -f "$ZONES_FILE" ]; then
        echo "0"
        return
    fi
    wc -l < "$ZONES_FILE"
}

# Функция извлечения данных из имени файла заглушки
parse_patch_filename() {
    local filename=$1
    local seek=$(echo "$filename" | sed -n 's/.*\.slow_patch_\([0-9]*\)_.*/\1/p')
    local count=$(echo "$filename" | sed -n 's/.*_\([0-9]*\)MB$/\1/p')
    echo "$seek|$count"
}

# Функция сканирования существующих заглушек
scan_existing_patches() {
    print_header "ПРОВЕРКА СУЩЕСТВУЮЩИХ ЗАГЛУШЕК"
    
    if [ ! -d "$TARGET_MOUNT" ]; then
        print_warning "Точка монтирования $TARGET_MOUNT не существует"
        return 1
    fi
    
    PATCH_FILES=$(find "$TARGET_MOUNT" -maxdepth 1 -name ".slow_patch_*" 2>/dev/null)
    
    if [ -z "$PATCH_FILES" ]; then
        print_info "Файлы-заглушки не найдены"
        return 0
    fi
    
    echo ""
    print_info "Найдены файлы-заглушки:"
    echo "----------------------------------------"
    
    local ADDED_COUNT=0
    local EXISTING_COUNT=0
    
    for patch_file in $PATCH_FILES; do
        local filename=$(basename "$patch_file")
        local parsed=$(parse_patch_filename "$filename")
        local seek=$(echo "$parsed" | cut -d'|' -f1)
        local count=$(echo "$parsed" | cut -d'|' -f2)
        
        if [ -n "$seek" ] && [ -n "$count" ]; then
            echo "  📁 $filename → seek=$seek, count=$count МБ"
            
            if add_zone "$seek" "$count"; then
                ADDED_COUNT=$((ADDED_COUNT + 1))
                echo "     → Добавлен в базу"
            else
                EXISTING_COUNT=$((EXISTING_COUNT + 1))
                echo "     → Уже есть в базе"
            fi
        else
            print_warning "  ⚠️ Не удалось разобрать имя: $filename"
        fi
    done
    
    echo "----------------------------------------"
    print_status "Добавлено новых зон: $ADDED_COUNT"
    print_info "Уже существовало: $EXISTING_COUNT"
    log_message "Сканирование заглушек: добавлено $ADDED_COUNT, существовало $EXISTING_COUNT"
}

# Функция инициализации базы данных
init_database() {
    print_header "ИНИЦИАЛИЗАЦИЯ БАЗЫ ДАННЫХ"
    
    if [ ! -f "$ZONES_FILE" ] || [ ! -s "$ZONES_FILE" ]; then
        print_info "База данных медленных зон не найдена или пуста"
        print_info "Сканируем диск на наличие существующих заглушек..."
        
        touch "$ZONES_FILE"
        scan_existing_patches
        
        ZONE_COUNT=$(get_zones_count)
        if [ "$ZONE_COUNT" -gt 0 ]; then
            echo ""
            print_status "База данных создана. Найдено зон: $ZONE_COUNT"
            echo ""
            echo "Содержимое базы:"
            echo "----------------------------------------"
            cat "$ZONES_FILE"
            echo "----------------------------------------"
        else
            print_info "База данных создана (пустая)"
        fi
    else
        ZONE_COUNT=$(get_zones_count)
        print_status "База данных загружена. Всего зон: $ZONE_COUNT"
    fi
    
    echo ""
}

# Функция автоматического определения дисков
detect_disks() {
    echo ""
    print_info "Автоматическое определение дисков..."
    echo ""
    
    echo "Доступные диски:"
    echo "----------------------------------------"
    lsblk -d -o NAME,SIZE,MODEL 2>/dev/null | grep -v "loop" || lsblk -d -o NAME,SIZE
    echo "----------------------------------------"
    echo ""
    
    echo "Смонтированные разделы:"
    echo "----------------------------------------"
    lsblk -o NAME,SIZE,MOUNTPOINT 2>/dev/null | grep -v "loop"
    echo "----------------------------------------"
    echo ""
}

# Функция настройки параметров
configure_settings() {
    print_header "НАСТРОЙКА ПАРАМЕТРОВ"
    
    detect_disks
    
    read -p "Диск для сканирования (например /dev/sda) [$DISK]: " input
    DISK=${input:-$DISK}
    
    while [ ! -b "$DISK" ]; do
        print_error "Диск $DISK не существует"
        detect_disks
        read -p "Введите корректный диск: " DISK
    done
    
    if [ -z "$PARTITION" ] || [ "$PARTITION" = "$DEFAULT_PARTITION" ]; then
        FIRST_PARTITION=$(lsblk -ln -o NAME "$DISK" 2>/dev/null | grep "${DISK##*/}" | grep -v "^${DISK##*/}$" | head -1)
        if [ -n "$FIRST_PARTITION" ]; then
            PARTITION="/dev/$FIRST_PARTITION"
            print_info "Автоматически определён раздел: $PARTITION"
        fi
    fi
    
    read -p "Раздел для бэкапа (необязательно) [$PARTITION]: " input
    PARTITION=${input:-$PARTITION}
    
    if [ -z "$TARGET_MOUNT" ] || [ "$TARGET_MOUNT" = "$DEFAULT_MOUNT" ]; then
        if [ -n "$PARTITION" ] && [ -b "$PARTITION" ]; then
            MOUNT_POINT=$(lsblk -ln -o MOUNTPOINT "$PARTITION" 2>/dev/null | head -1)
            if [ -n "$MOUNT_POINT" ] && [ "$MOUNT_POINT" != "" ]; then
                TARGET_MOUNT="$MOUNT_POINT"
                print_info "Автоматически определена точка монтирования: $TARGET_MOUNT"
            fi
        fi
    fi
    
    read -p "Точка монтирования [$TARGET_MOUNT]: " input
    TARGET_MOUNT=${input:-$TARGET_MOUNT}
    
    if [ ! -d "$TARGET_MOUNT" ]; then
        print_warning "Точка монтирования $TARGET_MOUNT не существует"
        read -p "Создать директорию? (y/n): " create_dir
        if [[ "$create_dir" =~ ^[YyДд] ]]; then
            mkdir -p "$TARGET_MOUNT"
            print_status "Директория создана"
        fi
    fi
    
    echo ""
    read -p "Минимальная скорость срабатывания (МБ/с) [$MIN_SPEED]: " input
    MIN_SPEED=${input:-$MIN_SPEED}
    
    read -p "Мегабайт ДО медленной зоны [$BEFORE_MB]: " input
    BEFORE_MB=${input:-$BEFORE_MB}
    
    read -p "Мегабайт ПОСЛЕ медленной зоны [$AFTER_MB]: " input
    AFTER_MB=${input:-$AFTER_MB}
    
    read -p "Время ожидания готовности диска (сек) [$WAIT_SEC]: " input
    WAIT_SEC=${input:-$WAIT_SEC}
    
    read -p "Размер блока сканирования (МБ) [$BLOCK_SIZE_MB]: " input
    BLOCK_SIZE_MB=${input:-$BLOCK_SIZE_MB}
    
    echo ""
    save_config
    
    print_status "Настройки сохранены"
    log_message "Настройки сохранены"
}

# Функция сканирования диска
scan_disk() {
    print_header "ШАГ 1: БЫСТРОЕ СКАНИРОВАНИЕ ДИСКА"
    
    if [ ! -b "$DISK" ]; then
        print_error "Диск $DISK не существует"
        echo "Проверьте настройки (пункт 5)"
        return 1
    fi
    
    export LC_NUMERIC=C
    
    DISK_SIZE_BYTES=$(blockdev --getsize64 "$DISK")
    DISK_SIZE_MB=$((DISK_SIZE_BYTES / 1024 / 1024))
    
    echo "Сканирование $DISK ($DISK_SIZE_MB МБ)"
    echo "Минимальная скорость: $MIN_SPEED МБ/с"
    echo "Зона защиты: $BEFORE_MB МБ до, $AFTER_MB МБ после"
    echo ""
    
    declare -A EXISTING_ZONES
    if [ -f "$ZONES_FILE" ]; then
        while IFS='|' read -r seek count; do
            EXISTING_ZONES["$seek"]="$count"
        done < "$ZONES_FILE"
    fi
    
    CURRENT_MB=0
    FOUND_ZONES=0
    SKIPPED_ZONES=0
    
    sync && echo 3 > /proc/sys/vm/drop_caches
    log_message "Начало сканирования диска $DISK"
    
    while [ $CURRENT_MB -lt $DISK_SIZE_MB ]; do
        
        PATCH_SEEK=$((CURRENT_MB - BEFORE_MB))
        if [ $PATCH_SEEK -lt 0 ]; then PATCH_SEEK=0; fi
        
        if [ -n "${EXISTING_ZONES[$PATCH_SEEK]}" ]; then
            SKIP_SIZE=${EXISTING_ZONES[$PATCH_SEEK]}
            echo -e "\n[🔒] Зона уже защищена: seek=$PATCH_SEEK, size=$SKIP_SIZE МБ, пропускаем"
            CURRENT_MB=$((CURRENT_MB + SKIP_SIZE))
            SKIPPED_ZONES=$((SKIPPED_ZONES + 1))
            continue
        fi
        
        START_TIME=$(date +%s.%N)
        
        timeout 2s dd if="$DISK" of=/dev/null bs=1M count=$BLOCK_SIZE_MB skip=$CURRENT_MB status=none 2>/dev/null
        DD_STATUS=$?
        
        END_TIME=$(date +%s.%N)
        ELAPSED=$(echo "$END_TIME - $START_TIME" | bc)
        
        if [ $DD_STATUS -eq 124 ] || (( $(echo "$ELAPSED > 2.0" | bc -l) )); then
            SPEED=0
        else
            if (( $(echo "$ELAPSED <= 0.001" | bc -l) )); then ELAPSED=0.001; fi
            SPEED=$(echo "$BLOCK_SIZE_MB / $ELAPSED" | bc)
        fi
        
        PERCENT=$(echo "scale=4; ($CURRENT_MB * 100) / $DISK_SIZE_MB" | bc)
        printf "\rПрогресс: %0.4f%% (%d/%d МБ) | Скорость: %0.1f МБ/с | Пропущено: %d" "$PERCENT" "$CURRENT_MB" "$DISK_SIZE_MB" "$SPEED" "$SKIPPED_ZONES"
        
        if (( $(echo "$SPEED < $MIN_SPEED" | bc -l) )); then
            echo -e "\n[!] Медленный сектор на $CURRENT_MB МБ (Скорость: $SPEED МБ/с)"
            log_message "Медленный сектор на $CURRENT_MB МБ, скорость $SPEED МБ/с"
            
            PATCH_SEEK=$((CURRENT_MB - BEFORE_MB))
            if [ $PATCH_SEEK -lt 0 ]; then PATCH_SEEK=0; fi
            
            PATCH_COUNT=$((BEFORE_MB + AFTER_MB))
            
            if add_zone "$PATCH_SEEK" "$PATCH_COUNT"; then
                FOUND_ZONES=$((FOUND_ZONES + 1))
                EXISTING_ZONES["$PATCH_SEEK"]="$PATCH_COUNT"
                echo "[->] Новая зона добавлена: seek=$PATCH_SEEK, count=$PATCH_COUNT МБ"
            else
                echo "[->] Зона уже существует, пропускаем"
            fi
            
            CURRENT_MB=$((CURRENT_MB + AFTER_MB))
            
            sync && echo 3 > /proc/sys/vm/drop_caches
            
            for i in $(seq $WAIT_SEC -1 1); do
                printf "\r[⏳] Ожидание диска... %d сек" "$i"
                sleep 1
            done
            echo -e "\n[✓] Диск готов. Продолжаем..."
            
            sync && echo 3 > /proc/sys/vm/drop_caches
        else
            CURRENT_MB=$((CURRENT_MB + BLOCK_SIZE_MB))
        fi
    done
    
    echo -e "\n"
    print_status "Сканирование завершено"
    print_info "Найдено новых медленных зон: $FOUND_ZONES"
    print_info "Пропущено уже защищённых зон: $SKIPPED_ZONES"
    print_info "Всего зон в базе: $(get_zones_count)"
    log_message "Сканирование завершено. Новых зон: $FOUND_ZONES"
}

# Функция создания заглушек
patch_slow_zones() {
    print_header "ШАГ 3: СОЗДАНИЕ ЗАГЛУШЕК (SPARSE FILES)"
    
    if [ ! -f "$ZONES_FILE" ] || [ ! -s "$ZONES_FILE" ]; then
        print_warning "Нет зон для заполнения!"
        print_info "Сначала запустите сканирование (пункт 1)"
        return 1
    fi
    
    ZONE_COUNT=$(get_zones_count)
    print_info "Найдено зон для создания: $ZONE_COUNT"
    
    if [ ! -d "$TARGET_MOUNT" ]; then
        print_error "Точка монтирования $TARGET_MOUNT не существует"
        return 1
    fi
    
    echo ""
    SUCCESS_COUNT=0
    SKIP_COUNT=0
    CURRENT_ZONE=0
    
    while IFS='|' read -r SEEK COUNT; do
        CURRENT_ZONE=$((CURRENT_ZONE + 1))
        PATCH_FILE="$TARGET_MOUNT/.slow_patch_${SEEK}_${COUNT}MB"
        
        if [ -f "$PATCH_FILE" ]; then
            print_info "[$CURRENT_ZONE/$ZONE_COUNT] Пропуск (существует): ${PATCH_FILE##*/}"
            SKIP_COUNT=$((SKIP_COUNT + 1))
            continue
        fi
        
        printf "[$CURRENT_ZONE/$ZONE_COUNT] Создание: %s (%d МБ)..." "${PATCH_FILE##*/}" "$COUNT"
        
        truncate -s "${COUNT}M" "$PATCH_FILE" 2>/dev/null
        
        if [ -f "$PATCH_FILE" ]; then
            chattr +i "$PATCH_FILE" 2>/dev/null
            echo -e "\r[$CURRENT_ZONE/$ZONE_COUNT] ✓ Создан: ${PATCH_FILE##*/}          "
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
            echo -e "\r[$CURRENT_ZONE/$ZONE_COUNT] ✗ Ошибка: ${PATCH_FILE##*/}          "
        fi
    done < "$ZONES_FILE"
    
    echo ""
    echo "------------------------------------------------"
    print_status "Операция завершена"
    echo "  Создано:   $SUCCESS_COUNT"
    echo "  Пропущено: $SKIP_COUNT"
    echo "  Всего зон: $ZONE_COUNT"
    log_message "Создание заглушек: создано $SUCCESS_COUNT, пропущено $SKIP_COUNT"
}

# Функция проверки диска
verify_disk() {
    print_header "ШАГ 4: ПРОВЕРКА ДИСКА"
    
    if [ ! -b "$DISK" ]; then
        print_error "Диск $DISK не существует"
        return 1
    fi
    
    export LC_NUMERIC=C
    
    DISK_SIZE_BYTES=$(blockdev --getsize64 "$DISK")
    DISK_SIZE_MB=$((DISK_SIZE_BYTES / 1024 / 1024))
    
    echo "Проверка $DISK ($DISK_SIZE_MB МБ)"
    echo "Порог скорости: $MIN_SPEED МБ/с"
    echo ""
    
    declare -A EXISTING_ZONES
    if [ -f "$ZONES_FILE" ]; then
        while IFS='|' read -r seek count; do
            EXISTING_ZONES["$seek"]="$count"
        done < "$ZONES_FILE"
    fi
    
    CURRENT_MB=0
    FOUND_ZONES=0
    SKIPPED_ZONES=0
    
    sync && echo 3 > /proc/sys/vm/drop_caches
    log_message "Начало проверки диска $DISK"
    
    while [ $CURRENT_MB -lt $DISK_SIZE_MB ]; do
        
        PATCH_SEEK=$((CURRENT_MB - BEFORE_MB))
        if [ $PATCH_SEEK -lt 0 ]; then PATCH_SEEK=0; fi
        
        PATCH_FILE="$TARGET_MOUNT/.slow_patch_${PATCH_SEEK}_*MB"
        PATCH_EXISTS=$(ls $PATCH_FILE 2>/dev/null | head -1)
        
        if [ -n "$PATCH_EXISTS" ]; then
            ZONE_SIZE=$(echo "$PATCH_EXISTS" | sed -n 's/.*_\([0-9]*\)MB$/\1/p')
            echo -e "\n[🔒] Заглушка найдена: seek=$PATCH_SEEK, size=$ZONE_SIZE МБ, пропускаем"
            CURRENT_MB=$((CURRENT_MB + ZONE_SIZE))
            SKIPPED_ZONES=$((SKIPPED_ZONES + 1))
            continue
        fi
        
        START_TIME=$(date +%s.%N)
        
        timeout 2s dd if="$DISK" of=/dev/null bs=1M count=$BLOCK_SIZE_MB skip=$CURRENT_MB status=none 2>/dev/null
        DD_STATUS=$?
        
        END_TIME=$(date +%s.%N)
        ELAPSED=$(echo "$END_TIME - $START_TIME" | bc)
        
        if [ $DD_STATUS -eq 124 ] || (( $(echo "$ELAPSED > 2.0" | bc -l) )); then
            SPEED=0
        else
            if (( $(echo "$ELAPSED <= 0.001" | bc -l) )); then ELAPSED=0.001; fi
            SPEED=$(echo "$BLOCK_SIZE_MB / $ELAPSED" | bc)
        fi
        
        PERCENT=$(echo "scale=4; ($CURRENT_MB * 100) / $DISK_SIZE_MB" | bc)
        printf "\rПрогресс: %0.4f%% (%d/%d МБ) | Скорость: %0.1f МБ/с | Пропущено: %d" "$PERCENT" "$CURRENT_MB" "$DISK_SIZE_MB" "$SPEED" "$SKIPPED_ZONES"
        
        if (( $(echo "$SPEED < $MIN_SPEED" | bc -l) )); then
            echo -e "\n[!] Новая медленная зона на $CURRENT_MB МБ (Скорость: $SPEED МБ/с)"
            
            NEW_SEEK=$((CURRENT_MB - BEFORE_MB))
            if [ $NEW_SEEK -lt 0 ]; then NEW_SEEK=0; fi
            
            NEW_COUNT=$((BEFORE_MB + AFTER_MB))
            
            if add_zone "$NEW_SEEK" "$NEW_COUNT"; then
                FOUND_ZONES=$((FOUND_ZONES + 1))
                echo "[->] Новая зона добавлена: seek=$NEW_SEEK, count=$NEW_COUNT МБ"
                
                NEW_PATCH_FILE="$TARGET_MOUNT/.slow_patch_${NEW_SEEK}_${NEW_COUNT}MB"
                truncate -s "${NEW_COUNT}M" "$NEW_PATCH_FILE" 2>/dev/null
                if [ -f "$NEW_PATCH_FILE" ]; then
                    chattr +i "$NEW_PATCH_FILE" 2>/dev/null
                    print_status "Заглушка создана: ${NEW_PATCH_FILE##*/}"
                fi
            fi
            
            CURRENT_MB=$((CURRENT_MB + AFTER_MB))
            
            sync && echo 3 > /proc/sys/vm/drop_caches
            
            for i in $(seq $WAIT_SEC -1 1); do
                printf "\r[⏳] Ожидание диска... %d сек" "$i"
                sleep 1
            done
            echo -e "\n[✓] Диск готов. Продолжаем..."
            
            sync && echo 3 > /proc/sys/vm/drop_caches
        else
            CURRENT_MB=$((CURRENT_MB + BLOCK_SIZE_MB))
        fi
    done
    
    echo -e "\n"
    echo "------------------------------------------------"
    print_status "Проверка завершена"
    echo "  Пропущено зон с заглушками: $SKIPPED_ZONES"
    echo "  Найдено новых проблемных зон: $FOUND_ZONES"
    echo "  Всего зон в базе: $(get_zones_count)"
    log_message "Проверка завершена. Новых зон: $FOUND_ZONES"
}

# Функция резервного копирования
backup_files() {
    print_header "ШАГ 2: РЕЗЕРВНОЕ КОПИРОВАНИЕ ФАЙЛОВ"
    
    if [ ! -f "$ZONES_FILE" ] || [ ! -s "$ZONES_FILE" ]; then
        print_warning "Нет зон для анализа. Сначала запустите сканирование (пункт 1)"
        return 1
    fi
    
    ZONE_COUNT=$(get_zones_count)
    print_info "Найдено зон для анализа: $ZONE_COUNT"
    
    if [ ! -d "$TARGET_MOUNT" ]; then
        print_error "Диск не смонтирован в $TARGET_MOUNT"
        return 1
    fi
    
    print_warning "ВНИМАНИЕ: Создание заглушек перезапишет существующие файлы в опасных зонах!"
    echo ""
    read -p "Продолжить? (y/n): " ANSWER
    
    if [[ ! "$ANSWER" =~ ^[YyДд] ]]; then
        print_info "Операция отменена"
        return 0
    fi
    
    print_status "Продолжаем"
}

# Функция меню настроек
configure_settings_menu() {
    configure_settings
    read -p "Нажмите Enter для продолжения..."
}

# Функция помощи
show_help() {
    print_header "ПОМОЩЬ - КАК РАБОТАЕТ СКРИПТ"
    
    echo ""
    echo "📖 ОСНОВНЫЕ ПРИНЦИПЫ"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    echo "Скрипт предназначен для работы с медленными (проблемными) секторами"
    echo "на жёстких дисках. Он находит области с низкой скоростью чтения и"
    echo "создаёт файлы-заглушки, которые блокируют использование этих областей."
    echo ""
    
    echo "📁 ФОРМАТ ИМЕНИ ЗАГЛУШКИ"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    echo "  .slow_patch_1500_1000MB"
    echo "       │         │"
    echo "       │         └── размер зоны в МБ (1000)"
    echo "       └──────────── смещение в МБ (1500)"
    echo ""
    
    echo "🔄 АЛГОРИТМ РАБОТЫ"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    echo "ПРИ ЗАПУСКЕ:"
    echo "  • Проверяет наличие slow_zones.txt"
    echo "  • Если нет → ищет .slow_patch_* на диске"
    echo "  • Добавляет найденные в базу"
    echo ""
    echo "СКАНИРОВАНИЕ (пункт 1):"
    echo "  • Загружает существующие зоны из базы"
    echo "  • Пропускает уже защищённые области"
    echo "  • Новые зоны добавляет в конец файла"
    echo ""
    echo "ПРОВЕРКА (пункт 4):"
    echo "  • Проверяет только незащищённые области"
    echo "  • Новые проблемы сразу добавляет в базу и создаёт заглушки"
    echo ""
    
    read -p "Нажмите Enter для продолжения..."
}

# Функция отображения меню
show_menu() {
    clear
    ZONE_COUNT=$(get_zones_count)
    
    if [ -d "$TARGET_MOUNT" ]; then
        PATCH_COUNT=$(ls "$TARGET_MOUNT"/.slow_patch_* 2>/dev/null | wc -l)
    else
        PATCH_COUNT=0
    fi
    
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════════════════╗"
    echo "║                    УПРАВЛЕНИЕ МЕДЛЕННЫМИ ЗОНАМИ ДИСКА                        ║"
    echo "║                              v$VERSION                                            ║"
    echo "╠══════════════════════════════════════════════════════════════════════════════╣"
    echo "║                                                                              ║"
    echo "║  [1] 🔍 Сканирование диска    - поиск новых медленных зон                    ║"
    echo "║  [2] 💾 Резервное копирование - (опционально)                                ║"
    echo "║  [3] 📝 Создание заглушек     - SPARSE FILES (мгновенно!)                    ║"
    echo "║  [4] ✅ Проверка диска        - верификация + авто-добавление                ║"
    echo "║  [5] ⚙️ Настройки              - изменение параметров                         ║"
    echo "║  [6] 📖 Помощь                - подробное описание                           ║"
    echo "║  [0] 🚪 Выход                                            	               ║"
    echo "║                                                                              ║"
    echo "╠══════════════════════════════════════════════════════════════════════════════╣"
    echo "║  📍 Диск: $DISK"
    echo "║  📂 Монтирование: $TARGET_MOUNT"
    echo "║  ⚡ Порог скорости: $MIN_SPEED МБ/с"
    echo "║  🛡️ Зона: $BEFORE_MB МБ до, $AFTER_MB МБ после"
    echo "║  📁 Зон в базе: $ZONE_COUNT | Заглушек на диске: $PATCH_COUNT"
    echo "╚══════════════════════════════════════════════════════════════════════════════╝"
    echo ""
}

# ============================================
# ГЛАВНЫЙ ЦИКЛ
# ============================================
main() {
    check_root
    check_dependencies
    
    # Загружаем настройки
    load_config
    
    # ПЕРВЫЙ ЗАПУСК: если файла конфигурации нет
    if [ ! -f "$CONFIG_FILE" ]; then
        print_header "ПЕРВЫЙ ЗАПУСК"
        print_info "Файл конфигурации не найден. Запущена интерактивная настройка."
        echo ""
        read -p "Нажмите Enter для начала настройки..."
        
        # Запускаем настройку
        configure_settings
        
        print_status "Настройка завершена!"
        echo ""
        read -p "Нажмите Enter для продолжения..."
    fi
    
    # Создаём файл лога
    touch "$LOG_FILE"
    log_message "=== Скрипт запущен (v$VERSION) ==="
    
    # Инициализация базы данных (сканирование существующих заглушек)
    init_database
    
    while true; do
        show_menu
        read -p "Выберите действие [0-6]: " choice
        
        case $choice in
            1) scan_disk; read -p "Нажмите Enter для продолжения..." ;;
            2) backup_files; read -p "Нажмите Enter для продолжения..." ;;
            3) patch_slow_zones; read -p "Нажмите Enter для продолжения..." ;;
            4) verify_disk; read -p "Нажмите Enter для продолжения..." ;;
            5) configure_settings_menu ;;
            6) show_help ;;
            0) 
                print_status "До свидания!"
                log_message "=== Скрипт завершён ==="
                exit 0 
                ;;
            *) 
                print_error "Неверный выбор. Введите 0-6"
                sleep 1 
                ;;
        esac
    done
}

# Запуск
main
