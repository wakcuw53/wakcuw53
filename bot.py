import asyncio
import logging
import sqlite3
from aiogram import Bot, Dispatcher, types, F
from aiogram.filters import Command
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.types import ReplyKeyboardMarkup, KeyboardButton, InlineKeyboardMarkup, InlineKeyboardButton

# --- НАСТРОЙКИ ---
API_TOKEN = '8376026777:AAHo4Ngt3FKmsLzEbaeZWSlmfE90yHWEnEo' 

logging.basicConfig(level=logging.INFO)
bot = Bot(token=API_TOKEN)
dp = Dispatcher()

# --- БАЗА ДАННЫХ ---
def db_start():
    conn = sqlite3.connect('market.db')
    cur = conn.cursor()
    # Таблица пользователей
    cur.execute('''CREATE TABLE IF NOT EXISTS users (
                    user_id INTEGER PRIMARY KEY,
                    username TEXT,
                    balance REAL DEFAULT 0,
                    inviter_id INTEGER DEFAULT 0)''')
    # Таблица товаров
    cur.execute('''CREATE TABLE IF NOT EXISTS items (
                    item_id INTEGER PRIMARY KEY AUTOINCREMENT,
                    owner_id INTEGER,
                    name TEXT,
                    description TEXT,
                    price REAL)''')
    conn.commit()
    conn.close()

# --- КЛАВИАТУРЫ (КНОПКИ) ---

# Главное меню (внизу экрана)
def get_main_kb():
    kb = [
        [KeyboardButton(text="📋 Список товаров"), KeyboardButton(text="➕ Создать товар")],
        [KeyboardButton(text="👤 Профиль")]
    ]
    return ReplyKeyboardMarkup(keyboard=kb, resize_keyboard=True)

# Кнопка отмены (для процесса создания)
def get_cancel_kb():
    kb = [[KeyboardButton(text="❌ Отмена")]]
    return ReplyKeyboardMarkup(keyboard=kb, resize_keyboard=True)

# Инлайн кнопки для профиля (БОНУС УБРАН)
def get_profile_kb():
    kb = [
        [InlineKeyboardButton(text="💳 Пополнить баланс", callback_data="deposit")]
    ]
    return InlineKeyboardMarkup(inline_keyboard=kb)

# --- МАШИНА СОСТОЯНИЙ (FSM) ---
class NewItem(StatesGroup):
    name = State()
    desc = State()
    price = State()

# --- ЛОГИКА БОТА ---

@dp.message(Command("start"))
async def cmd_start(message: types.Message):
    user_id = message.from_user.id
    username = message.from_user.full_name
    
    # Регистрация
    conn = sqlite3.connect('market.db')
    cur = conn.cursor()
    cur.execute("INSERT OR IGNORE INTO users (user_id, username) VALUES (?, ?)", (user_id, username))
    conn.commit()
    conn.close()
    
    await message.answer(
        "👋 Добро пожаловать на торговую площадку!\nИспользуйте меню внизу.",
        reply_markup=get_main_kb()
    )

# 1. ПРОФИЛЬ
@dp.message(F.text == "👤 Профиль")
async def profile_handler(message: types.Message):
    user_id = message.from_user.id
    
    conn = sqlite3.connect('market.db')
    cur = conn.cursor()
    cur.execute("SELECT username, balance, inviter_id FROM users WHERE user_id = ?", (user_id,))
    user = cur.fetchone()
    conn.close()

    if user:
        name, balance, inviter = user
        inviter_text = "Никто" if inviter == 0 else f"ID: {inviter}"
        text = (
            f"👤 **ЛИЧНЫЙ КАБИНЕТ**\n"
            f"➖➖➖➖➖➖➖➖\n"
            f"👤 Имя: {name}\n"
            f"💰 Баланс: **{balance} ₽**\n"
            f"🤝 Вас пригласил: {inviter_text}"
        )
        await message.answer(text, parse_mode="Markdown", reply_markup=get_profile_kb())

# Обработка кнопки пополнения (ЗАГЛУШКА)
@dp.callback_query(F.data == "deposit")
async def deposit_handler(callback: types.CallbackQuery):
    await callback.answer("Платежная система в разработке. Свяжитесь с админом.", show_alert=True)

# 2. СОЗДАНИЕ ТОВАРА
@dp.message(F.text == "➕ Создать товар")
async def start_create(message: types.Message, state: FSMContext):
    await state.set_state(NewItem.name)
    await message.answer("Введите **название** товара:", reply_markup=get_cancel_kb(), parse_mode="Markdown")

# Кнопка отмены
@dp.message(F.text == "❌ Отмена")
async def cancel_action(message: types.Message, state: FSMContext):
    await state.clear()
    await message.answer("Действие отменено.", reply_markup=get_main_kb())

@dp.message(NewItem.name)
async def add_name(message: types.Message, state: FSMContext):
    await state.update_data(name=message.text)
    await state.set_state(NewItem.desc)
    await message.answer("Введите **описание** товара:")

@dp.message(NewItem.desc)
async def add_desc(message: types.Message, state: FSMContext):
    await state.update_data(desc=message.text)
    await state.set_state(NewItem.price)
    await message.answer("Укажите **цену** товара (число):")

@dp.message(NewItem.price)
async def add_price(message: types.Message, state: FSMContext):
    try:
        price = float(message.text)
        if price <= 0: raise ValueError
    except ValueError:
        await message.answer("Пожалуйста, введите корректную цену (положительное число).")
        return

    data = await state.get_data()
    conn = sqlite3.connect('market.db')
    cur = conn.cursor()
    cur.execute("INSERT INTO items (owner_id, name, description, price) VALUES (?, ?, ?, ?)", 
                (message.from_user.id, data['name'], data['desc'], price))
    conn.commit()
    conn.close()
    
    await state.clear()
    await message.answer(f"✅ Товар **{data['name']}** выставлен за {price} ₽", parse_mode="Markdown", reply_markup=get_main_kb())

# 3. СПИСОК ТОВАРОВ
@dp.message(F.text == "📋 Список товаров")
async def list_items(message: types.Message):
    user_id = message.from_user.id
    conn = sqlite3.connect('market.db')
    cur = conn.cursor()
    # Выбираем чужие товары
    cur.execute("SELECT item_id, name, price FROM items WHERE owner_id != ?", (user_id,))
    items = cur.fetchall()
    conn.close()

    if not items:
        await message.answer("😔 На рынке пока пусто или только ваши товары.")
        return

    await message.answer("👇 Выберите товар для покупки:")
    
    # Выводим товары по одному с кнопкой "Купить"
    for item in items:
        i_id, name, price = item
        kb = InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(text=f"Купить за {price} ₽", callback_data=f"buy_{i_id}")]
        ])
        await message.answer(f"📦 **{name}**", reply_markup=kb, parse_mode="Markdown")

# 4. ПОКУПКА ТОВАРА
@dp.callback_query(F.data.startswith("buy_"))
async def process_buy(callback: types.CallbackQuery):
    item_id = int(callback.data.split("_")[1])
    buyer_id = callback.from_user.id

    conn = sqlite3.connect('market.db')
    cur = conn.cursor()
    
    # Получаем данные о товаре и продавце
    cur.execute("SELECT price, owner_id, name FROM items WHERE item_id = ?", (item_id,))
    item = cur.fetchone()
    
    if not item:
        await callback.answer("Товар уже продан или удален.", show_alert=True)
        conn.close()
        return

    price, seller_id, item_name = item
    
    # Проверяем баланс покупателя
    cur.execute("SELECT balance FROM users WHERE user_id = ?", (buyer_id,))
    buyer_balance = cur.fetchone()[0]

    if buyer_balance < price:
        await callback.answer(f"Недостаточно средств! Вам нужно еще {price - buyer_balance} ₽", show_alert=True)
        conn.close()
        return

    # --- ТРАНЗАКЦИЯ ---
    try:
        # 1. Снимаем у покупателя
        cur.execute("UPDATE users SET balance = balance - ? WHERE user_id = ?", (price, buyer_id))
        # 2. Начисляем продавцу
        cur.execute("UPDATE users SET balance = balance + ? WHERE user_id = ?", (price, seller_id))
        # 3. Удаляем товар с рынка
        cur.execute("DELETE FROM items WHERE item_id = ?", (item_id,))
        conn.commit()
        
        await callback.message.edit_text(f"✅ Вы успешно купили **{item_name}**!", parse_mode="Markdown")
        await callback.answer("Поздравляем с покупкой!")
        
        try:
            await bot.send_message(seller_id, f"💰 Ваш товар **{item_name}** купили! Вам начислено {price} ₽.")
        except:
            pass
            
    except Exception as e:
        print(f"Ошибка транзакции: {e}")
        await callback.answer("Произошла ошибка при покупке.")
    finally:
        conn.close()

# Запуск
async def main():
    db_start()
    await dp.start_polling(bot)

if __name__ == "__main__":
    asyncio.run(main())