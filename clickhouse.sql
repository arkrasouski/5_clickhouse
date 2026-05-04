--Создание таблицы

CREATE TABLE user_events (
    user_id UInt32,
    event_type String,
    points_spent UInt32,
    event_time DateTime
) ENGINE = MergeTree()
ORDER BY (event_time, user_id);

--Добавляем таблице time-to-live 30 суток

ALTER TABLE user_events MODIFY TTL DATE(event_time) + INTERVAL 30 DAY;

-- Строим агрегированную таблицу

CREATE TABLE user_events_aggr
(
    event_type String,
    event_date Date,
    uniq_users AggregateFunction(uniq, UInt32),
    total_spent AggregateFunction(sum, UInt32),
    total_events AggregateFunction(count)
)
ENGINE = AggregatingMergeTree()
ORDER BY (event_type, toDate(event_date))

TTL DATE(event_date) + INTERVAL 180 DAY;

CREATE MATERIALIZED VIEW mv_user_events_aggr
TO user_events_aggr
AS
SELECT
    event_type,
    toDate(event_time) AS event_date,
    uniqState(user_id) AS uniq_users,
    sumState(points_spent) AS total_spent,
    countState() AS total_events
FROM user_events
GROUP BY
    event_type,
    toDate(event_time);

--Заполнение таблицы данными

INSERT INTO user_events VALUES
-- События 10 дней назад
(1, 'login', 0, now() - INTERVAL 10 DAY),
(2, 'signup', 0, now() - INTERVAL 10 DAY),
(3, 'login', 0, now() - INTERVAL 10 DAY),

-- События 7 дней назад
(1, 'login', 0, now() - INTERVAL 7 DAY),
(2, 'login', 0, now() - INTERVAL 7 DAY),
(3, 'purchase', 30, now() - INTERVAL 7 DAY),

-- События 5 дней назад
(1, 'purchase', 50, now() - INTERVAL 5 DAY),
(2, 'logout', 0, now() - INTERVAL 5 DAY),
(4, 'login', 0, now() - INTERVAL 5 DAY),

-- События 3 дня назад
(1, 'login', 0, now() - INTERVAL 3 DAY),
(3, 'purchase', 70, now() - INTERVAL 3 DAY),
(5, 'signup', 0, now() - INTERVAL 3 DAY),

-- События вчера
(2, 'purchase', 20, now() - INTERVAL 1 DAY),
(4, 'logout', 0, now() - INTERVAL 1 DAY),
(5, 'login', 0, now() - INTERVAL 1 DAY),

-- События сегодня
(1, 'purchase', 25, now()),
(2, 'login', 0, now()),
(3, 'logout', 0, now()),
(6, 'signup', 0, now()),
(6, 'purchase', 100, now());

-- создаю представления для чтения данных из агрегированной таблицы
CREATE VIEW v_user_events_aggr AS
SELECT
	event_date,
    event_type,
    uniqMerge(uniq_users) AS unique_users,
    sumMerge(total_spent) AS total_spent,
    countMerge(total_events) AS total_actions
FROM user_events_aggr
GROUP BY event_type, event_date;

SELECT * FROM v_user_events_aggr ORDER BY event_date, event_type;

-- Считаю Retention
-- Нахожу дату первого события для каждого пользователя
WITH user_reg AS (
    SELECT
        user_id,
        MIN(toDate(event_time)) AS reg_day
    FROM user_events
    GROUP BY user_id
)
-- CTE смещения дней
, user_activity AS (
    SELECT
        reg.user_id,
        reg.reg_day,
        dateDiff('day', reg.reg_day, toDate(ev.event_time)) AS day_offset
    FROM user_reg reg
    JOIN user_events ev ON reg.user_id = ev.user_id
    WHERE toDate(ev.event_time) BETWEEN reg.reg_day AND reg.reg_day + INTERVAL 6 DAY
)
-- CTE номеря дня с регистрации действий пользователей
, user_days AS (
    SELECT
        user_id,
        reg_day,
        countIf(day_offset != 0) AS active_days
    FROM user_activity
    GROUP BY user_id, reg_day
)
-- Итоговый расчет: active_days != 0 значит это день, отличный от дня регистрации
SELECT
    count() AS total_users_day_0,
    -- Если пользователь был активен хотя бы один из дней 1-7, его активный день > 0
    countIf(active_days != 0) AS returned_in_7_days,
    round(countIf(active_days != 0) / count() * 100, 2) AS retention_7d_percent
FROM user_days;
-- total_users_day_0|returned_in_7_days|retention_7d_percent
-- 6	5	83.33