SELECT OrcamentoId
FROM dbo.fn_OrcamentosVencidos(CONVERT(date, '20261016', 112))
OPTION (RECOMPILE);
