WITH	gates (opcode, arity, matrix) AS MATERIALIZED
	(
	VALUES
		('X', 1, ARRAY[
			[0, 1],
			[1, 0]
			]::COMPLEX[][]),
		('Y', 1, ARRAY[
			[0, -(0, 1)],
			[-(0, 1), 0]
			]::COMPLEX[][]),
		('Z', 1, ARRAY[
			[1, 0],
			[0, -1]
			]::COMPLEX[][]),
		('H', 1, ARRAY[
			[1 / SQRT(2), 1 / SQRT(2)],
			[1 / SQRT(2), -1 / SQRT(2)]
			]::COMPLEX[][])
	UNION ALL
	SELECT	REPEAT('C', arity - 1) || 'X', arity, matrix
	FROM	GENERATE_SERIES(2, 5) arity
	CROSS JOIN LATERAL
		(
		WITH	constants AS
			(
			SELECT	(1 << (arity - 1)) - 1 AS mask,
				(1 << arity) - 1 AS rank
			)
		SELECT	ARRAY_AGG(cols ORDER BY row) AS matrix
		FROM	constants
		CROSS JOIN LATERAL
			(
			SELECT	row, ARRAY_AGG((CASE WHEN row & mask = mask AND col & mask = mask THEN row <> col ELSE row = col END)::INT::COMPLEX ORDER BY col) cols
			FROM	GENERATE_SERIES(0, rank) row
			CROSS JOIN
				GENERATE_SERIES(0, rank) col
			GROUP BY
				row
			) gate
		) toffoli
			
	)
SELECT	opcode, arity,
	(
	SELECT	STRING_AGG(cols::TEXT, E'\n' ORDER BY row)
	FROM	(
		SELECT	row, ARRAY_AGG(coefficient ORDER BY col) cols
		FROM	(
			SELECT	(r, i)::COMPLEX coefficient,
				(ordinality - 1) / (1 << arity) AS row, (ordinality -1 ) % (1 << arity) AS col
			FROM	UNNEST(matrix) WITH ORDINALITY matrix (r, i, ordinality)
			) q
		GROUP BY
			row
		) q
	) matrix
FROM	gates;
