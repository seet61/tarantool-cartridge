-- модуль проверки аргументов в функциях
local checks = require('checks')

-- модуль работы с числами
local decnumber = require('ldecnumber')

local function init_spaces()
    local customer = box.schema.space.create(
	-- имя спейса для хранения пользователей
	'customer',
	-- дополнительные параметры
	{
	    -- формат хранимых кортежей
	    format = {
		{'customer_id', 'unsigned'},
		{'bucket_id', 'unsigned'},
		{'name', 'string'}
	    },
	    -- создание спейса, только если его нет
	    if_not_exists = true,
	}
    )
    
    -- индекс по id пользователя
    customer:create_index('customer_id', {
	parts = {'customer_id'},
	if_not_exists = true,
    })
    
    -- индекс по bucket
    customer:create_index('bucket_id', {
	parts = {'bucket_id'},
	unique = false,
	if_not_exists = true,
    })
    
    -- спейс для счетов
    local account = box.schema.space.create('account', {
	format = {
	    {'account_id', 'unsigned'},
	    {'customer_id', 'unsigned'},
	    {'bucket_id', 'unsigned'},
	    {'balance', 'string'},
	    {'name', 'string'},
	},
	if_not_exists = true,
    })
    
    -- индексы аналогичны
    account:create_index('account_id', {
	parts = {'account_id'},
	if_not_exists = true,
    })
    
    account:create_index('customer_id', {
	parts = {'customer_id'},
	if_not_exists = true,
    })
    
    account:create_index('bucket_id', {
	parts = {'bucket_id'},
	unique = false,
	if_not_exists = true,
    })
    
end

local function customer_add(customer)
    customer.accounts = customer.accounts or {}
    
    -- открытие транзакции
    box.begin()
    
    -- вставка в customer
    box.space.customer:insert({
	customer.customer_id,
	customer.bucket_id,
	customer.name
    })
    
    for _, account in ipairs(customer.accounts) do
	-- вставка в account
	box.space.account:insert({
	    account.account_id,
	    customer.customer_id,
	    customer.bucket_id,
	    '0.00',
	    account.name
	})
    end
    
    -- коммит
    box.commit()
    return true
end

local function customer_update_balance(customer_id, account_id, amount)
    -- проверка аргументов функции
    checks('number', 'number', 'string')
    
    -- находим требуемый счет в БД
    local account = box.space.account:get(account_id)
    -- проверяем найден ли счет
    if account == nil then 
	return nil
    end
    
    -- проверяем принадлежит ли запрашиваемый счет пользователю
    if account.customer_id ~= customer_id then
	error('Invalid account_id')
    end
    
    -- конвертируем строку даланса в число
    local balance_decimal = decnumber.tonumber(account.balance)
    balance_decimal = balance_decimal + amount
    if balance_decimal:isnan() then
	error('Invalid amount')
    end
    
    -- округляем до 2ч знаков после зпт и конвертируем обратно в строку
    local new_balance = balance_decimal:rescale(-2):tostring()
    
    -- обновляем баланс
    box.space.account:update({ account_id }, {
	{'=', 4, new_balance}
    })
    
    return new_balance
end

local function customer_lookup(customer_id)
    checks('number')
    
    local customer = box.space.customer:get(customer_id)
    if customer == nil then
	return nil
    end
    customer = {
	customer_id = customer.customer_id;
	name = customer.name;
    }
    local accounts = {}
    for _, account in box.space.account.index.customer_id:pairs(customer_id) do
	table.insert(accounts, {
	    account_id = account.account_id;
	    name = account.name;
	    balance = account.balance;
	})
    end
    customer.accounts = accounts;
    
    return customer
end

local function init(opts)
    if opts.is_master then
	-- инициализация спейсов
	init_spaces()
	
	box.schema.user.create('root', { password = 'secret', if_not_exists = true})
	box.schema.user.grant('root', 'read,write,execute, drop', 'universe', nil, {if_not_exists=true})
	
	box.schema.func.create('customer_add', {if_not_exists = true})
	box.schema.func.create('customer_lookup', {if_not_exists = true})
	box.schema.func.create('customer_update_balance', {if_not_exists = true})
	
	box.schema.role.grant('public', 'execute', 'function', 'customer_add', {if_not_exists = true})
	box.schema.role.grant('public', 'execute', 'function', 'customer_lookup', {if_not_exists = true})
	box.schema.role.grant('public', 'execute', 'function', 'customer_update_balance', {if_not_exists = true})
    end
    
    rawset(_G, 'customer_add', customer_add)
    rawset(_G, 'customer_lookup', customer_lookup)
    rawset(_G, 'customer_update_balance', customer_update_balance)
    
    return true
end

return {
    role_name = 'storage',
    init = init,
    dependencies = {
	'cartridge.roles.vshard-storage',
    },
}