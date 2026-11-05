SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET NUMERIC_ROUNDABORT OFF;
SET NOCOUNT ON;

IF EXISTS (SELECT 1 FROM dbo.Orcamentos)
    THROW 50002, 'O script exige um banco descartável sem orçamentos.', 1;

DROP INDEX IF EXISTS IX_Orcamentos_Pendente_Validade ON dbo.Orcamentos;

DECLARE @DataReferencia date = CONVERT(date, '20261016', 112);
DECLARE @ClienteId int;

INSERT INTO dbo.Clientes (Nome)
VALUES (N'Cliente fictício de benchmark');
SET @ClienteId = CONVERT(int, SCOPE_IDENTITY());

SET IDENTITY_INSERT dbo.Orcamentos ON;

WITH Digitos AS
(
    SELECT valor
    FROM (VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9)) AS d(valor)
),
Numeros AS
(
    SELECT TOP (100000)
        ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS Numero
    FROM Digitos AS a
    CROSS JOIN Digitos AS b
    CROSS JOIN Digitos AS c
    CROSS JOIN Digitos AS d
    CROSS JOIN Digitos AS e
)
INSERT INTO dbo.Orcamentos
    (Id, ClienteId, Titulo, DataEmissao, Validade, Situacao,
     ClienteRegistrado_Nome, NegocioRegistrado_Nome)
SELECT
    Numero,
    @ClienteId,
    CONCAT(N'Benchmark ', Numero),
    CONVERT(date, '20261001', 112),
    CASE
        WHEN Numero % 40 = 0 THEN DATEADD(day, -1, @DataReferencia)
        WHEN Numero % 200 = 20 THEN NULL
        WHEN Numero % 40 = 20 THEN @DataReferencia
        ELSE DATEADD(day, 60, @DataReferencia)
    END,
    CASE WHEN Numero % 20 = 0 THEN 1 ELSE 0 END,
    CASE WHEN Numero % 20 = 0 THEN N'Cliente histórico' END,
    CASE WHEN Numero % 20 = 0 THEN N'Negócio histórico' END
FROM Numeros
ORDER BY Numero;

SET IDENTITY_INSERT dbo.Orcamentos OFF;

IF (SELECT COUNT_BIG(*) FROM dbo.Orcamentos) <> 100000
    THROW 50003, 'A massa deveria conter 100.000 orçamentos.', 1;
IF (SELECT COUNT_BIG(*) FROM dbo.Orcamentos WHERE Situacao = 1) <> 5000
    THROW 50004, 'A massa deveria conter 5.000 orçamentos pendentes.', 1;
IF (SELECT COUNT_BIG(*) FROM dbo.Orcamentos WHERE Situacao = 1 AND Validade < @DataReferencia) <> 2500
    THROW 50005, 'A massa deveria conter 2.500 orçamentos vencidos.', 1;
IF (SELECT COUNT_BIG(*) FROM dbo.Orcamentos WHERE Situacao = 1 AND Validade = @DataReferencia) <> 2000
    THROW 50006, 'A massa deveria conter 2.000 orçamentos com validade no limite da data.', 1;
IF (SELECT COUNT_BIG(*) FROM dbo.Orcamentos WHERE Situacao = 1 AND Validade IS NULL) <> 500
    THROW 50007, 'A massa deveria conter 500 orçamentos pendentes sem validade.', 1;
