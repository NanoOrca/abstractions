CREATE OR REPLACE FUNCTION dex.insert_uniswap(start_ts timestamptz, end_ts timestamptz=now(), start_block numeric=0, end_block numeric=9e18) RETURNS integer
LANGUAGE plpgsql AS $function$
DECLARE r integer;
BEGIN
WITH rows AS (
    INSERT INTO dex.trades (
        block_time,
        token_bought_symbol,
        token_sold_symbol,
        token_bought_amount,
        token_sold_amount,
        project,
        version,
        category,
        buyer,
        seller,
        token_bought_amount_raw,
        token_sold_amount_raw,
        usd_amount,
        token_bought_address,
        token_sold_address,
        exchange_contract_address,
        tx_hash,
        tx_from,
        tx_to,
        trace_address,
        evt_index,
        trade_id
    )
    SELECT
        dexs.block_time,
        erc20a.symbol AS token_a_symbol,
        erc20b.symbol AS token_b_symbol,
        token_bought_amount_raw / 10 ^ erc20a.decimals AS token_bought_amount,
        token_sold_amount_raw / 10 ^ erc20b.decimals AS token_sold_amount,
        project,
        version,
        category,
        coalesce(buyer, tx."from") as trader_a, -- subqueries rely on this COALESCE to avoid redundant joins with the transactions table
        seller,
        token_bought_amount_raw,
        token_sold_amount_raw,
        coalesce(
            usd_amount,
            token_bought_amount_raw / 10 ^ pa.decimals * pa.price,
            token_sold_amount_raw / 10 ^ pb.decimals * pb.price
        ) as usd_amount,
        token_bought_address,
        token_sold_address,
        exchange_contract_address,
        tx_hash,
        tx."from" as tx_from,
        tx."to" as tx_to,
        trace_address,
        evt_index,
        row_number() OVER (PARTITION BY project, tx_hash, evt_index, trace_address ORDER BY version, category) AS trade_id
    FROM (
        -- Uniswap v1 TokenPurchase
        SELECT
            t.evt_block_time AS block_time,
            'Uniswap' AS project,
            '1' AS version,
            'DEX' AS category,
            buyer AS buyer,
            t.contract_address AS seller,	--On AMMs the contract pair is always the seller (the LP is the seller)
            tokens_bought AS token_bought_amount_raw,
            eth_sold AS token_sold_amount_raw,
            NULL::numeric AS usd_amount,
            f.token AS token_bought_address,
            '\xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2'::bytea AS token_sold_address, --Using WETH for easier joining with USD price table
            t.contract_address exchange_contract_address,
            t.evt_tx_hash AS tx_hash,
            NULL::integer[] AS trace_address,
            t.evt_index
        FROM
            uniswap. "Exchange_evt_TokenPurchase" t
        INNER JOIN uniswap. "Factory_evt_NewExchange" f ON f.exchange = t.contract_address

        UNION ALL

        -- Uniswap v1 EthPurchase
        SELECT
            t.evt_block_time AS block_time,
            'Uniswap' AS project,
            '1' AS version,
            'DEX' AS category,
            buyer AS buyer,
            t.contract_address AS seller,	--On AMMs the contract pair is always the seller (the LP is the seller)
            eth_bought token_bought_amount_raw,
            tokens_sold token_sold_amount_raw,
            NULL::numeric AS usd_amount,
            '\xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2'::bytea token_bought_address, --Using WETH for easier joining with USD price table
            f.token AS token_sold_address,
            t.contract_address exchange_contract_address,
            t.evt_tx_hash AS tx_hash,
            NULL::integer[] AS trace_address,
            t.evt_index
        FROM
            uniswap. "Exchange_evt_EthPurchase" t
        INNER JOIN uniswap. "Factory_evt_NewExchange" f ON f.exchange = t.contract_address

        UNION ALL
        -- Uniswap v2
        SELECT
            t.evt_block_time AS block_time,
            'Uniswap' AS project,
            '2' AS version,
            'DEX' AS category,
            t."to" AS buyer, --The address the AMM is sending the tokens to.
            t.contract_address AS seller,	--On AMMs the contract pair is always the seller (the LP is the seller)
            CASE WHEN "amount0Out" = 0 THEN "amount1Out" ELSE "amount0Out" END AS token_bought_amount_raw, --AmountXout is tokens leaving the AMM
            CASE WHEN "amount0In" = 0 THEN "amount1In" ELSE "amount0In" END AS token_sold_amount_raw,	--AmountXin is tokens arriving at the AMM
            NULL::numeric AS usd_amount,
            CASE WHEN "amount0Out" = 0 THEN f.token1 ELSE f.token0 END AS token_bought_address, -- If amount0out = 0, token 1 is being bought (leaving AMM)
            CASE WHEN "amount0In" = 0 THEN f.token1 ELSE f.token0 END AS token_sold_address,	-- If amount0in = 0, token 1 is being sold (going to AMM)
            t.contract_address AS exchange_contract_address,
            t.evt_tx_hash AS tx_hash,
            NULL::integer[] AS trace_address,
            t.evt_index
        FROM
            uniswap_v2."Pair_evt_Swap" t
        INNER JOIN uniswap_v2."Factory_evt_PairCreated" f ON f.pair = t.contract_address
        WHERE t.contract_address NOT IN (
            '\xed9c854cb02de75ce4c9bba992828d6cb7fd5c71', -- remove WETH-UBOMB wash trading pair
            '\x854373387e41371ac6e307a1f29603c6fa10d872' ) -- remove FEG/ETH token pair


        UNION ALL
        --Uniswap v3
        SELECT
            t.evt_block_time AS block_time,
            'Uniswap' AS project,
            '3' AS version,
            'DEX' AS category,
            t."recipient" AS buyer,		-- Who the AMM is sending tokens to
            t.contract_address AS seller,	--On AMMs the contract pair is always the seller (the LP is the seller)
            CASE WHEN amount0 < 0 THEN abs(amount0) ELSE abs(amount1) END AS token_bought_amount_raw, -- The number on the name of the column indicates the token (token0 or token1).
            CASE WHEN amount0 < 0 THEN amount1 ELSE amount0 END AS token_sold_amount_raw,	-- Negative amounts means tokens leaving the LP
            NULL::numeric AS usd_amount,
            CASE WHEN amount0 < 0 THEN f.token0 ELSE f.token1 END AS token_bought_address, -- Amount0 < 0 means token0 is leaving the AMM
            CASE WHEN amount0 < 0 THEN f.token1 ELSE f.token0 END AS token_sold_address,	-- Amount0 < 0 means token1 is arrriving at the AMM
            t.contract_address as exchange_contract_address,
            t.evt_tx_hash AS tx_hash,
            NULL::integer[] AS trace_address,
            t.evt_index
        FROM
            uniswap_v3."Pair_evt_Swap" t
        INNER JOIN uniswap_v3."Factory_evt_PoolCreated" f ON f.pool = t.contract_address

    ) dexs
    INNER JOIN ethereum.transactions tx
        ON dexs.tx_hash = tx.hash
        AND tx.block_time >= start_ts
        AND tx.block_time < end_ts
        AND tx.block_number >= start_block
        AND tx.block_number < end_block
    LEFT JOIN erc20.tokens erc20a ON erc20a.contract_address = dexs.token_a_address
    LEFT JOIN erc20.tokens erc20b ON erc20b.contract_address = dexs.token_b_address
    LEFT JOIN prices.usd pa ON pa.minute = date_trunc('minute', dexs.block_time)
        AND pa.contract_address = dexs.token_a_address
        AND pa.minute >= start_ts
        AND pa.minute < end_ts
    LEFT JOIN prices.usd pb ON pb.minute = date_trunc('minute', dexs.block_time)
        AND pb.contract_address = dexs.token_b_address
        AND pb.minute >= start_ts
        AND pb.minute < end_ts
    WHERE dexs.block_time >= start_ts
    AND dexs.block_time < end_ts

    ON CONFLICT DO NOTHING
    RETURNING 1
)
SELECT count(*) INTO r from rows;
RETURN r;
END
$function$;

-- fill 2018
SELECT dex.insert_uniswap(
    '2018-01-01',
    '2019-01-01',
    (SELECT max(number) FROM ethereum.blocks WHERE time < '2018-01-01'),
    (SELECT max(number) FROM ethereum.blocks WHERE time <= '2019-01-01')
)
WHERE NOT EXISTS (
    SELECT *
    FROM dex.trades
    WHERE block_time > '2018-01-01'
    AND block_time <= '2019-01-01'
    AND project = 'Uniswap'
);

-- fill 2019
SELECT dex.insert_uniswap(
    '2019-01-01',
    '2020-01-01',
    (SELECT max(number) FROM ethereum.blocks WHERE time < '2019-01-01'),
    (SELECT max(number) FROM ethereum.blocks WHERE time <= '2020-01-01')
)
WHERE NOT EXISTS (
    SELECT *
    FROM dex.trades
    WHERE block_time > '2019-01-01'
    AND block_time <= '2020-01-01'
    AND project = 'Uniswap'
);

-- fill 2020
SELECT dex.insert_uniswap(
    '2020-01-01',
    '2021-01-01',
    (SELECT max(number) FROM ethereum.blocks WHERE time < '2020-01-01'),
    (SELECT max(number) FROM ethereum.blocks WHERE time <= '2021-01-01')
)
WHERE NOT EXISTS (
    SELECT *
    FROM dex.trades
    WHERE block_time > '2020-01-01'
    AND block_time <= '2021-01-01'
    AND project = 'Uniswap'
);

-- fill 2021
SELECT dex.insert_uniswap(
    '2021-01-01',
    now(),
    (SELECT max(number) FROM ethereum.blocks WHERE time < '2021-01-01'),
    (SELECT MAX(number) FROM ethereum.blocks where time < now() - interval '20 minutes')
)
WHERE NOT EXISTS (
    SELECT *
    FROM dex.trades
    WHERE block_time > '2021-01-01'
    AND block_time <= now() - interval '20 minutes'
    AND project = 'Uniswap'
);

INSERT INTO cron.job (schedule, command)
VALUES ('*/10 * * * *', $$
    SELECT dex.insert_uniswap(
        (SELECT max(block_time) - interval '1 days' FROM dex.trades WHERE project='Uniswap'),
        (SELECT now() - interval '20 minutes'),
        (SELECT max(number) FROM ethereum.blocks WHERE time < (SELECT max(block_time) - interval '1 days' FROM dex.trades WHERE project='Uniswap')),
        (SELECT MAX(number) FROM ethereum.blocks where time < now() - interval '20 minutes'));
$$)
ON CONFLICT (command) DO UPDATE SET schedule=EXCLUDED.schedule;
