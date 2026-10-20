-- Создаем таблицу витрины customer_report_datamart для агрегированных данных по клиентам
DROP TABLE IF EXISTS dwh.customer_report_datamart;

CREATE TABLE IF NOT EXISTS dwh.customer_report_datamart (
    id BIGINT GENERATED ALWAYS AS IDENTITY NOT NULL, -- идентификатор записи
    customer_id BIGINT NOT NULL, -- идентификатор заказчика
    customer_name VARCHAR NOT NULL, -- Ф.И.О. заказчика
    customer_address VARCHAR NOT NULL, -- адрес заказчика
    customer_birthday DATE NOT NULL, -- дата рождения заказчика
    customer_email VARCHAR NOT NULL, -- электронная почта заказчика
    customer_money NUMERIC(15,2) NOT NULL, -- сумма, которую потратил заказчик за месяц
    platform_money NUMERIC(15,2) NOT NULL, -- сумма, которую заработала платформа (10% от customer_money) за месяц
    count_order BIGINT NOT NULL, -- количество заказов у заказчика за месяц
    avg_price_order NUMERIC(10,2) NOT NULL, -- средняя стоимость одного заказа у заказчика за месяц
    median_time_order_completed NUMERIC(10,1), -- медианное время в днях от создания до завершения заказа за месяц
    top_product_category VARCHAR NOT NULL, -- самая популярная категория товаров у заказчика за месяц
    top_craftsman_id BIGINT, -- идентификатор самого популярного мастера у заказчика за месяц
    count_order_created BIGINT NOT NULL, -- количество созданных заказов за месяц
    count_order_in_progress BIGINT NOT NULL, -- количество заказов в процессе изготовки за месяц
    count_order_delivery BIGINT NOT NULL, -- количество заказов в доставке за месяц
    count_order_done BIGINT NOT NULL, -- количество завершённых заказов за месяц
    count_order_not_done BIGINT NOT NULL, -- количество незавершённых заказов за месяц
    report_period VARCHAR NOT NULL, -- отчётный период в формате 'YYYY-MM'
    CONSTRAINT customer_report_datamart_pk PRIMARY KEY (id)
);

-- Создаем таблицу для хранения дат инкрементальных загрузок
DROP TABLE IF EXISTS dwh.load_dates_customer_report_datamart;

CREATE TABLE IF NOT EXISTS dwh.load_dates_customer_report_datamart (
    id BIGINT GENERATED ALWAYS AS IDENTITY NOT NULL,
    load_dttm DATE NOT NULL,
    CONSTRAINT load_dates_customer_report_datamart_pk PRIMARY KEY (id)
);

-- Скрипт инкрементального обновления витрины customer_report_datamart

WITH 
-- Получаем данные по заказам, клиентам, товарам и мастерам, изменённым после последней загрузки
dwh_delta AS (
    SELECT
        dcs.customer_id,
        dcs.customer_name,
        dcs.customer_address,
        dcs.customer_birthday,
        dcs.customer_email,
        fo.order_id,
        fo.order_created_date,
        fo.order_completion_date,
        fo.order_status,
        dp.product_id,
        dp.product_type,
        dp.product_price,
        fo.craftsman_id,
        dc.craftsman_name,
        dc.craftsman_address,
        dc.craftsman_birthday,
        dc.craftsman_email,
        TO_CHAR(fo.order_created_date, 'YYYY-MM') AS report_period,
        dcs.load_dttm AS customer_load_dttm,
        dc.load_dttm AS craftsman_load_dttm,
        dp.load_dttm AS product_load_dttm,
        fo.load_dttm AS order_load_dttm
    FROM dwh.f_order fo
    INNER JOIN dwh.d_customer dcs ON fo.customer_id = dcs.customer_id
    INNER JOIN dwh.d_product dp ON fo.product_id = dp.product_id
    INNER JOIN dwh.d_craftsman dc ON fo.craftsman_id = dc.craftsman_id
    WHERE -- Выбираем только данные, которые были изменены после последней даты загрузки
        fo.load_dttm > COALESCE((SELECT MAX(load_dttm) FROM dwh.load_dates_customer_report_datamart), '1900-01-01')
        OR dcs.load_dttm > COALESCE((SELECT MAX(load_dttm) FROM dwh.load_dates_customer_report_datamart), '1900-01-01')
        OR dp.load_dttm > COALESCE((SELECT MAX(load_dttm) FROM dwh.load_dates_customer_report_datamart), '1900-01-01')
        OR dc.load_dttm > COALESCE((SELECT MAX(load_dttm) FROM dwh.load_dates_customer_report_datamart), '1900-01-01')
),
-- Получаем клиентов, для которых есть изменения
dwh_update_delta AS (
    SELECT DISTINCT customer_id FROM dwh_delta WHERE customer_id IS NOT NULL
),
-- Собираем данные по каждому клиенту и периоду отчёта
dwh_delta_agg AS (
    SELECT
        dd.customer_id,
        dd.customer_name,
        dd.customer_address,
        dd.customer_birthday,
        dd.customer_email,
        SUM(dd.product_price) AS customer_money, -- сумма потраченных денег
        SUM(dd.product_price) * 0.1 AS platform_money, -- 10% дохода платформы
        COUNT(dd.order_id) AS count_order, -- количество заказов
        AVG(dd.product_price) AS avg_price_order, -- средняя цена заказа
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY (dd.order_completion_date - dd.order_created_date)) AS median_time_order_completed, -- медианное время выполнения заказа
        dd.report_period
    FROM (
        SELECT
            customer_id,
            customer_name,
            customer_address,
            customer_birthday,
            customer_email,
            order_id,
            product_price,
            order_created_date,
            order_completion_date,
            report_period
        FROM dwh_delta
    ) dd
    GROUP BY dd.customer_id, dd.customer_name, dd.customer_address, dd.customer_birthday, dd.customer_email, dd.report_period
),
top_product_category AS ( -- Определяем самую популярную категорию товаров по каждому клиенту и периоду
    SELECT
        customer_id,
        report_period,
        product_type AS top_product_category,
        RANK() OVER (PARTITION BY customer_id, report_period ORDER BY COUNT(*) DESC) AS rank_popular
    FROM dwh_delta
    GROUP BY customer_id, report_period, product_type
),
top_craftsman AS ( -- Определяем самого популярного мастера по каждому клиенту и периоду
    SELECT
        customer_id,
        report_period,
        craftsman_id AS top_craftsman_id,
        RANK() OVER (PARTITION BY customer_id, report_period ORDER BY COUNT(*) DESC) AS rank_popular
    FROM dwh_delta
    GROUP BY customer_id, report_period, craftsman_id
),
order_status_counts AS ( -- Считаем количество заказов по статусам для каждого клиента и периода
    SELECT
        customer_id,
        report_period,
        SUM(CASE WHEN order_status = 'created' THEN 1 ELSE 0 END) AS count_order_created,
        SUM(CASE WHEN order_status = 'in progress' THEN 1 ELSE 0 END) AS count_order_in_progress,
        SUM(CASE WHEN order_status = 'delivery' THEN 1 ELSE 0 END) AS count_order_delivery,
        SUM(CASE WHEN order_status = 'done' THEN 1 ELSE 0 END) AS count_order_done,
        SUM(CASE WHEN order_status != 'done' THEN 1 ELSE 0 END) AS count_order_not_done
    FROM dwh_delta
    GROUP BY customer_id, report_period
),
dwh_delta_insert_result AS ( -- Объединяем все данные для вставки и обновления
    SELECT
        agg.customer_id,
        agg.customer_name,
        agg.customer_address,
        agg.customer_birthday,
        agg.customer_email,
        agg.customer_money,
        agg.platform_money,
        agg.count_order,
        agg.avg_price_order,
        agg.median_time_order_completed,
        tpc.top_product_category,
        tc.top_craftsman_id,
        osc.count_order_created,
        osc.count_order_in_progress,
        osc.count_order_delivery,
        osc.count_order_done,
        osc.count_order_not_done,
        agg.report_period
    FROM dwh_update_delta ud
    INNER JOIN dwh_delta_agg agg ON ud.customer_id = agg.customer_id
    LEFT JOIN (
        SELECT customer_id, report_period, top_product_category
        FROM top_product_category
        WHERE rank_popular = 1
    ) tpc ON agg.customer_id = tpc.customer_id AND agg.report_period = tpc.report_period
    LEFT JOIN (
        SELECT customer_id, report_period, top_craftsman_id
        FROM top_craftsman
        WHERE rank_popular = 1
    ) tc ON agg.customer_id = tc.customer_id AND agg.report_period = tc.report_period
    INNER JOIN order_status_counts osc ON agg.customer_id = osc.customer_id AND agg.report_period = osc.report_period
),
dwh_delta_update_result AS (
    SELECT * FROM dwh_delta_insert_result
),
insert_delta AS ( -- Вставляем новые записи в витрину
    INSERT INTO dwh.customer_report_datamart (
        customer_id,
        customer_name,
        customer_address,
        customer_birthday,
        customer_email,
        customer_money,
        platform_money,
        count_order,
        avg_price_order,
        median_time_order_completed,
        top_product_category,
        top_craftsman_id,
        count_order_created,
        count_order_in_progress,
        count_order_delivery,
        count_order_done,
        count_order_not_done,
        report_period
    )
    SELECT
        customer_id,
        customer_name,
        customer_address,
        customer_birthday,
        customer_email,
        customer_money,
        platform_money,
        count_order,
        avg_price_order,
        median_time_order_completed,
        top_product_category,
        top_craftsman_id,
        count_order_created,
        count_order_in_progress,
        count_order_delivery,
        count_order_done,
        count_order_not_done,
        report_period
    FROM dwh_delta_insert_result ddir
    WHERE NOT EXISTS (
        SELECT 1 FROM dwh.customer_report_datamart crd
        WHERE crd.customer_id = ddir.customer_id AND crd.report_period = ddir.report_period
    )
),
update_delta AS ( -- Обновляем существующие записи в витрине
    UPDATE dwh.customer_report_datamart crd
    SET
        customer_name = ddir.customer_name,
        customer_address = ddir.customer_address,
        customer_birthday = ddir.customer_birthday,
        customer_email = ddir.customer_email,
        customer_money = ddir.customer_money,
        platform_money = ddir.platform_money,
        count_order = ddir.count_order,
        avg_price_order = ddir.avg_price_order,
        median_time_order_completed = ddir.median_time_order_completed,
        top_product_category = ddir.top_product_category,
        top_craftsman_id = ddir.top_craftsman_id,
        count_order_created = ddir.count_order_created,
        count_order_in_progress = ddir.count_order_in_progress,
        count_order_delivery = ddir.count_order_delivery,
        count_order_done = ddir.count_order_done,
        count_order_not_done = ddir.count_order_not_done
    FROM dwh_delta_update_result ddir
    WHERE crd.customer_id = ddir.customer_id AND crd.report_period = ddir.report_period
),
insert_load_date AS ( -- Записываем дату последней загрузки в таблицу
    INSERT INTO dwh.load_dates_customer_report_datamart (load_dttm)
    SELECT GREATEST(
        COALESCE(MAX(customer_load_dttm), '1900-01-01'),
        COALESCE(MAX(craftsman_load_dttm), '1900-01-01'),
        COALESCE(MAX(product_load_dttm), '1900-01-01'),
        COALESCE(MAX(order_load_dttm), '1900-01-01')
    ) FROM dwh_delta
)
SELECT 'increment customer_report_datamart';