
-- ============================================================
-- 1. Анализ продаж по месяцам
-- ============================================================

-- Рассчитываем основные показатели продаж:
-- количество заказов, общую выручку и средний чек (AOV).
-- Данные группируются по календарным месяцам.

SELECT
    -- Извлекаем год и месяц из даты заказа
    strftime('%Y-%m', i.InvoiceDate) AS month,

    -- Подсчитываем количество уникальных заказов.
    -- DISTINCT необходим, так как один заказ может
    -- содержать несколько товарных позиций.
    COUNT(DISTINCT i.InvoiceId) AS orders,

    -- Выручка = цена товара * количество проданных единиц
    ROUND(SUM(il.UnitPrice * il.Quantity), 2) AS revenue,

    -- Средний чек = общая выручка / количество заказов
    ROUND(
        SUM(il.UnitPrice * il.Quantity)
        / COUNT(DISTINCT i.InvoiceId),
        2
    ) AS aov

FROM Invoice AS i

-- Объединяем заказы с их товарными позициями
JOIN InvoiceLine AS il
    ON il.InvoiceId = i.InvoiceId

-- Группируем продажи по месяцам
GROUP BY strftime('%Y-%m', i.InvoiceDate)

-- Сортируем результаты в хронологическом порядке
ORDER BY month;


-- ============================================================
-- 2. Анализ географии продаж
-- ============================================================

-- Определяем страны, которые приносят наибольшую выручку.
-- Используем страну, указанную в платёжных данных заказа
-- (BillingCountry), а не страну проживания клиента.

SELECT
    i.BillingCountry AS country,

    -- Количество уникальных заказов из каждой страны
    COUNT(DISTINCT i.InvoiceId) AS orders,

    -- Общая выручка по стране
    ROUND(
        SUM(il.UnitPrice * il.Quantity),
        2
    ) AS revenue,

    -- Средний чек заказа по стране
    ROUND(
        1.0 * SUM(il.UnitPrice * il.Quantity)
        / COUNT(DISTINCT i.InvoiceId),
        2
    ) AS aov

FROM Invoice AS i

JOIN InvoiceLine AS il
    ON il.InvoiceId = i.InvoiceId

-- Объединяем заказы одной страны
GROUP BY i.BillingCountry

-- Сортируем страны по убыванию выручки
ORDER BY revenue DESC

-- Выводим 10 крупнейших рынков
LIMIT 10;


-- ============================================================
-- 3. Сегментация клиентов по повторным покупкам
-- ============================================================

-- Разделяем клиентов на три группы:
-- no purchase — не совершали покупок;
-- one-time    — совершили одну покупку;
-- repeat      — совершили более одной покупки.
--
-- Для каждого сегмента рассчитываем количество клиентов
-- и его долю от общей клиентской базы.

WITH customer_orders AS (

    -- Сначала подсчитываем количество заказов каждого клиента
    SELECT
        c.CustomerId,
        COUNT(i.InvoiceId) AS order_count

    FROM Customer AS c

    -- LEFT JOIN позволяет сохранить клиентов без заказов.
    -- Для таких клиентов COUNT(i.InvoiceId) вернёт 0.
    LEFT JOIN Invoice AS i
        ON i.CustomerId = c.CustomerId

    GROUP BY c.CustomerId
)

SELECT
    -- Присваиваем клиенту сегмент по количеству заказов
    CASE
        WHEN order_count = 0 THEN 'no purchase'
        WHEN order_count = 1 THEN 'one-time'
        ELSE 'repeat'
    END AS segment,

    -- Количество клиентов в сегменте
    COUNT(*) AS customers,

    -- Доля сегмента в общей клиентской базе (%)
    ROUND(
        100.0 * COUNT(*)
        / (SELECT COUNT(*) FROM Customer),
        2
    ) AS customer_share_pct

FROM customer_orders

GROUP BY segment

-- Сначала выводим наиболее многочисленные сегменты
ORDER BY customers DESC;


-- ============================================================
-- 4. RFM-анализ клиентской базы
-- ============================================================

-- RFM — метод сегментации клиентов по трём показателям:
--
-- Recency   — давность последней покупки;
-- Frequency — количество совершённых заказов;
-- Monetary  — общая сумма покупок.
--
-- На основе этих показателей присваиваем клиентам оценки
-- от 1 до 3 и формируем четыре условных сегмента:
-- High Value, At Risk, Loyal, Regular.


-- ЭТАП 1. Рассчитываем показатели Frequency и Monetary,
-- а также дату последней покупки каждого клиента.

WITH customer_metrics AS (

    SELECT
        c.CustomerId,

        -- Объединяем имя и фамилию клиента
        c.FirstName || ' ' || c.LastName AS customer_name,

        -- Дата последней покупки
        MAX(DATE(i.InvoiceDate)) AS last_purchase,

        -- Общее количество заказов
        COUNT(i.InvoiceId) AS frequency,

        -- Суммарные расходы клиента
        ROUND(SUM(i.Total), 2) AS monetary

    FROM Customer c

    JOIN Invoice i
        ON c.CustomerId = i.CustomerId

    GROUP BY c.CustomerId
),


-- ЭТАП 2. Рассчитываем Recency.
-- Это количество дней между последней покупкой клиента
-- и самой поздней датой заказа во всём датасете.
--
-- Используем максимальную дату датасета, а не текущую,
-- поскольку анализируем исторические данные.

rfm_values AS (

    SELECT
        *,

        -- JULIANDAY() переводит даты в числовой формат,
        -- позволяя рассчитать разницу между ними.
        CAST(
            JULIANDAY(
                (SELECT MAX(DATE(InvoiceDate)) FROM Invoice)
            ) - JULIANDAY(last_purchase)
            AS INTEGER
        ) AS recency

    FROM customer_metrics
),


-- ЭТАП 3. Присваиваем RFM-оценки.
--
-- NTILE(3) делит клиентов на три приблизительно равные
-- группы по каждому показателю.
--
-- Оценка 3 соответствует лучшему значению:
-- R = 3 — наиболее недавние покупки;
-- F = 3 — наиболее высокая частота покупок;
-- M = 3 — наиболее высокие расходы.
--
-- Важно: NTILE может разделить клиентов с одинаковыми
-- значениями показателя между разными группами.

rfm_scores AS (

    SELECT
        *,

        -- Чем меньше Recency, тем лучше оценка.
        -- Поэтому сортируем по убыванию.
        NTILE(3) OVER (
            ORDER BY recency DESC
        ) AS r_score,

        -- Чем больше Frequency, тем лучше оценка
        NTILE(3) OVER (
            ORDER BY frequency ASC
        ) AS f_score,

        -- Чем больше Monetary, тем лучше оценка
        NTILE(3) OVER (
            ORDER BY monetary ASC
        ) AS m_score

    FROM rfm_values
),


-- ЭТАП 4. Формируем клиентские сегменты.
--
-- CASE WHEN проверяет условия последовательно.
-- Клиент попадает в первый подходящий сегмент.
--
-- High Value — недавняя покупка, относительно высокие
--              частота и сумма покупок.
-- At Risk    — давно не совершал покупок.
-- Loyal      — высокие частота и сумма покупок.
-- Regular    — остальные клиенты.

segments AS (

    SELECT
        *,

        CASE
            WHEN r_score = 3
                 AND f_score >= 2
                 AND m_score >= 2
                THEN 'High Value'

            WHEN r_score = 1
                THEN 'At Risk'

            WHEN f_score = 3
                 AND m_score = 3
                THEN 'Loyal'

            ELSE 'Regular'
        END AS segment

    FROM rfm_scores
)


-- ЭТАП 5. Рассчитываем показатели для каждого сегмента.

SELECT
    segment,

    -- Количество клиентов в сегменте
    COUNT(*) AS customers,

    -- Среднее количество заказов на клиента
    ROUND(AVG(frequency), 2) AS avg_orders,

    -- Средняя сумма покупок на клиента
    ROUND(AVG(monetary), 2) AS avg_spent,

    -- Совокупная выручка от клиентов сегмента
    ROUND(SUM(monetary), 2) AS total_revenue

FROM segments

GROUP BY segment

-- Сортируем сегменты по общей выручке
ORDER BY total_revenue DESC;


-- ============================================================
-- 5. Анализ продаж по музыкальным жанрам
-- ============================================================

-- Определяем наиболее прибыльные жанры.
-- Для каждого жанра рассчитываем:
-- количество проданных позиций;
-- суммарную выручку;
-- долю в общей выручке (%);
-- место в рейтинге по выручке.

WITH genre_sales AS (

    -- Сначала агрегируем продажи по жанрам
    SELECT
        g.Name AS genre,

        -- Количество строк продаж.
        -- В Chinook Quantity обычно равно 1;
        -- при других значениях COUNT не равен числу единиц.
        COUNT(il.InvoiceLineId) AS tracks_sold,

        -- Выручка от продаж жанра
        ROUND(
            SUM(il.UnitPrice * il.Quantity),
            2
        ) AS revenue

    FROM InvoiceLine il

    -- Определяем трек для каждой позиции заказа
    JOIN Track t
        ON il.TrackId = t.TrackId

    -- Получаем жанр соответствующего трека
    JOIN Genre g
        ON t.GenreId = g.GenreId

    GROUP BY g.GenreId, g.Name
)

SELECT
    genre,
    tracks_sold,
    revenue,

    -- Доля жанра в общей выручке магазина.
    -- SUM(revenue) OVER () вычисляет общую выручку
    -- по всем жанрам без сворачивания строк.
    ROUND(
        100.0 * revenue / SUM(revenue) OVER (),
        2
    ) AS revenue_share_pct,

    -- Ранжирование жанров по выручке.
    -- DENSE_RANK присваивает одинаковый ранг жанрам
    -- с одинаковой выручкой и не пропускает номера.
    DENSE_RANK() OVER (
        ORDER BY revenue DESC
    ) AS revenue_rank

FROM genre_sales

-- Наиболее прибыльные жанры выводятся первыми
ORDER BY revenue DESC;


-- ============================================================
-- 6. Анализ продаж по исполнителям
-- ============================================================

-- Находим 10 исполнителей и медиапроектов,
-- которые приносят наибольшую выручку.
--
-- Используем связи:
-- InvoiceLine -> Track -> Album -> Artist.
--
-- Для каждого исполнителя рассчитываем:
-- количество проданных позиций;
-- суммарную выручку;
-- долю в общей выручке магазина.

WITH artist_sales AS (

    SELECT
        ar.Name AS artist,

        -- Количество строк продаж
        COUNT(il.InvoiceLineId) AS tracks_sold,

        -- Выручка от продаж контента исполнителя
        SUM(il.UnitPrice * il.Quantity) AS revenue

    FROM InvoiceLine il

    -- Получаем данные о продаваемом треке
    JOIN Track t
        ON il.TrackId = t.TrackId

    -- Определяем альбом трека
    JOIN Album al
        ON t.AlbumId = al.AlbumId

    -- Определяем исполнителя или медиапроект
    JOIN Artist ar
        ON al.ArtistId = ar.ArtistId

    GROUP BY ar.ArtistId, ar.Name
)

SELECT
    artist,
    tracks_sold,

    -- Округляем выручку до двух знаков
    ROUND(revenue, 2) AS revenue,

    -- Рассчитываем долю исполнителя в общей выручке.
    -- Оконная функция применяется до LIMIT,
    -- поэтому знаменатель включает всех исполнителей,
    -- а не только 10 лучших.
    ROUND(
        100.0 * revenue / SUM(revenue) OVER (),
        2
    ) AS revenue_share_pct

FROM artist_sales

ORDER BY revenue DESC

-- Выводим только десять лидеров по выручке
LIMIT 10;
