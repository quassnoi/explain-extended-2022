WITH	RECURSIVE
	settings AS
	(
	SELECT	9 AS qubits,
		ARRAY[0, 1, 2, 3] AS measurements,
		'
H: 8;
Z: 8;
H: 0;
H: 1;
H: 2;
H: 3;

CX: 0,4;
CX: 1,4;
CX: 0,5;
CX: 2,5;
CX: 1,6;
CX: 3,6;
CX: 2,7;
CX: 3,7;
CCCCX: 4,5,6,7,8;
CX: 0,4;
CX: 1,4;
CX: 0,5;
CX: 2,5;
CX: 1,6;
CX: 3,6;
CX: 2,7;
CX: 3,7;

H: 0;
H: 1;
H: 2;
H: 3;
X: 0;
X: 1;
X: 2;
X: 3;
H: 3;
CCCX: 0,1,2,3;
H: 3;
X: 0;
X: 1;
X: 2;
X: 3;
H: 0;
H: 1;
H: 2;
H: 3;

CX: 0,4;
CX: 1,4;
CX: 0,5;
CX: 2,5;
CX: 1,6;
CX: 3,6;
CX: 2,7;
CX: 3,7;
CCCCX: 4,5,6,7,8;
CX: 0,4;
CX: 1,4;
CX: 0,5;
CX: 2,5;
CX: 1,6;
CX: 3,6;
CX: 2,7;
CX: 3,7;

H: 0;
H: 1;
H: 2;
H: 3;
X: 0;
X: 1;
X: 2;
X: 3;
H: 3;
CCCX: 0,1,2,3;
H: 3;
X: 0;
X: 1;
X: 2;
X: 3;
H: 0;
H: 1;
H: 2;
H: 3;
' AS program
	),
	basis AS
	(
	SELECT	eigenstate
	FROM	settings
	CROSS JOIN
		generate_series(0, (1 << qubits) - 1) AS eigenstate
	),
	gates (opcode, arity, matrix) AS MATERIALIZED
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
			
	),
	circuit AS MATERIALIZED
	(
	SELECT	step, parts[1] AS opcode, inputs::INT[]
	FROM	settings
	CROSS JOIN
		REGEXP_SPLIT_TO_TABLE(program, E'\\s*;\\s*') WITH ORDINALITY instructions(instruction, step)
	CROSS JOIN LATERAL
		REGEXP_MATCHES(instruction, E'(\\w+)\\s*:\\s(.*)') parts
	CROSS JOIN LATERAL
		REGEXP_SPLIT_TO_ARRAY(parts[2], E'\\s*,\\s*') inputs
	),
	evolutions AS
	(
	SELECT	0 AS step, steps, state
	FROM	(
		SELECT	COUNT(*) AS steps
		FROM	circuit
		) steps
	CROSS JOIN
		(
		SELECT	ARRAY_AGG((CASE eigenstate WHEN 0 THEN 1 ELSE 0 END)::COMPLEX ORDER BY eigenstate) AS state
		FROM	basis
		) initial_state
	UNION ALL
	SELECT	step + 1, steps, new_state.state
	FROM	evolutions
	CROSS JOIN
		settings
	CROSS JOIN LATERAL
		(
		WITH	circuit_gate AS MATERIALIZED
			(
			SELECT	*
			FROM	circuit
			WHERE	circuit.step = evolutions.step + 1
			),
			gate AS MATERIALIZED
			(
			SELECT	arity, matrix, inputs
			FROM	circuit_gate
			JOIN	gates
			ON	gates.opcode = circuit_gate.opcode
			),
			identity_qubits AS MATERIALIZED
			(
			SELECT	ARRAY_AGG(input ORDER BY input) identity_qubits
			FROM	gate
			CROSS JOIN LATERAL
				(
				SELECT	input
				FROM	GENERATE_SERIES(0, qubits - 1) input
				EXCEPT
				SELECT	input
				FROM	UNNEST(inputs) input
				) q
			),
			unitary AS
			(
			SELECT	circuit_identity_basis | circuit_gate_row_basis AS row,
				circuit_identity_basis | circuit_gate_col_basis AS col,
				coefficient
			FROM	gate
			CROSS JOIN
				identity_qubits
			CROSS JOIN LATERAL
				(
				WITH	circuit_gate_basis AS
					(
					SELECT	gate_basis, circuit_gate_basis
					FROM	GENERATE_SERIES(0, (1 << arity) - 1) gate_basis
					CROSS JOIN LATERAL
						(
						SELECT	COALESCE(BIT_OR(1 << inputs[input + 1]), 0) AS circuit_gate_basis
						FROM	GENERATE_SERIES(0, arity - 1) input
						WHERE	gate_basis & (1 << input) > 0
						) circuit_gate_basis
					)
				SELECT	row.circuit_gate_basis AS circuit_gate_row_basis,
					col.circuit_gate_basis AS circuit_gate_col_basis,
					matrix[row.gate_basis + 1][col.gate_basis + 1]::COMPLEX AS coefficient
				FROM	circuit_gate_basis row
				CROSS JOIN
					circuit_gate_basis col
				) circuit_gate_basis
			CROSS JOIN LATERAL
				(
				SELECT	circuit_identity_basis
				FROM	GENERATE_SERIES(0, (1 << (qubits - arity)) - 1) identity_basis
				CROSS JOIN LATERAL
					(
					SELECT	COALESCE(BIT_OR(1 << identity_qubit), 0) AS circuit_identity_basis
					FROM	UNNEST(identity_qubits) WITH ORDINALITY AS identity_qubits (identity_qubit, input)
					WHERE	identity_basis & (1 << (input - 1)::INT) > 0
					) circuit_identity_basis
				) circuit_identity_basis
			WHERE	coefficient <> 0::COMPLEX
			),
			state AS
			(
			WITH	state AS
				(
				SELECT	(r, i)::COMPLEX amplitude, ordinality - 1 AS eigenstate
				FROM	UNNEST(state) WITH ORDINALITY state (r, i, ordinality)
				)
			SELECT	row, SUM(amplitude * coefficient) AS amplitude
			FROM	state
			JOIN	unitary
			ON	col = eigenstate
			GROUP BY
				row
			)
		SELECT	ARRAY_AGG(amplitude ORDER BY row) state
		FROM	state
		) new_state
	WHERE	step < steps
	)
SELECT	eigenstate_bits, probability
FROM	(
	SELECT	state
	FROM	evolutions
	WHERE	step = steps
	) state
CROSS JOIN
	settings
CROSS JOIN LATERAL
	(
	WITH	probabilities AS
		(
		SELECT	norm((r, i)::COMPLEX) AS probability, ordinality - 1 AS eigenstate
		FROM	UNNEST(state) WITH ORDINALITY state(r, i, ordinality)
		)
	SELECT	RIGHT(measurement_eigenstate::BIT(36)::TEXT, ARRAY_LENGTH(measurements, 1)) AS eigenstate_bits,
		SUM(probability)::NUMERIC(4, 4) AS probability
	FROM	probabilities
	CROSS JOIN LATERAL
		(
		SELECT	BIT_OR(((eigenstate >> qubit) & 1) << position::INT - 1) AS measurement_eigenstate
		FROM	UNNEST(measurements) WITH ORDINALITY measurements (qubit, position)
		) measurement
	GROUP BY
		measurement_eigenstate
	) measurements
WHERE	probability >= 0.0001
ORDER BY
	probability DESC, eigenstate_bits

