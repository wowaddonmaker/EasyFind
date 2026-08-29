-- Tests for Apps/Calc/Core.lua money math (gold/silver/copper literals).

local H = require("Harness")
local env = H.newEnv()
local ns = H.newNs(env)
env.EasyFind._ns = ns

-- Core.lua returns nothing; it populates ns.Calculator in place.
H.loadModule("Apps/Calc/Core.lua", env, ns)
H.assertNotNil(ns.Calculator._calculator, "Core.lua must populate ns.Calculator")

local tests = {}

local function resultOf(expr)
    local data = ns.Calculator:EvaluateCalculatorExpression(expr)
    return data and data.calculatorResult
end

function tests.money_divideGoldGivesSilver()
    -- The CurseForge request, verbatim: 4g / 5 = 80s.
    H.assertEq(resultOf("4g / 5"), "80s")
end

function tests.money_compoundLiteral()
    H.assertEq(resultOf("4g50s + 0"), "4g 50s")
    H.assertEq(resultOf("4g 50s + 0"), "4g 50s")
    H.assertEq(resultOf("1g2s3c * 1"), "1g 2s 3c")
end

function tests.money_conversionWithoutOperator()
    H.assertEq(resultOf("450s"), "4g 50s")
    H.assertEq(resultOf("10000c"), "1g")
end

function tests.money_arithmeticAcrossUnits()
    H.assertEq(resultOf("2g + 30s + 4c"), "2g 30s 4c")
    H.assertEq(resultOf("(1g + 50s) / 3"), "50s")
    H.assertEq(resultOf("4g * 2"), "8g")
end

function tests.money_wordUnits()
    H.assertEq(resultOf("4gold / 5"), "80s")
    H.assertEq(resultOf("150silver + 0"), "1g 50s")
end

function tests.money_negativeAndZero()
    H.assertEq(resultOf("50s - 1g"), "-50s")
    H.assertEq(resultOf("1g - 1g"), "0c")
end

function tests.money_fractionRoundsToCopper()
    -- 4g / 3 = 13333.33c -> rounds to whole copper.
    H.assertEq(resultOf("4g / 3"), "1g 33s 33c")
end

function tests.money_decimalLiteral()
    H.assertEq(resultOf("1.5g + 0"), "1g 50s")
end

function tests.money_goldThousandsGrouping()
    H.assertEq(resultOf("1000g + 0"), "1,000g")
    H.assertEq(resultOf("100000g / 4"), "25,000g")
    H.assertEq(resultOf("1234567g + 89s"), "1,234,567g 89s")
    -- Grouped INPUT already worked (the tokenizer eats digit-group commas).
    H.assertEq(resultOf("1,000g / 2"), "500g")
    -- Below four digits nothing changes.
    H.assertEq(resultOf("999g + 0"), "999g")
end

function tests.plainMathUnchanged()
    H.assertEq(resultOf("2 + 2"), "4")
    H.assertEq(resultOf("10 / 4"), "2.5")
end

function tests.looksLikeInput_money()
    local c = ns.Calculator._calculator
    H.assertTrue(c.LooksLikeInput("80s"))
    H.assertTrue(c.LooksLikeInput("4g / 5"))
    H.assertTrue(c.LooksLikeInput("4gold"))
    H.assertFalse(c.LooksLikeInput("sword"))
    -- "2h sword" passes the cheap prefilter (pre-existing digit-letter
    -- heuristic) but must never EVALUATE to a result row.
    H.assertNil(ns.Calculator:EvaluateCalculatorExpression("2h sword"))
end

function tests.money_unitRunBoundary()
    -- "4gs" is not a money literal ("gs" is no unit); the old ident path
    -- takes it and evaluation fails cleanly.
    H.assertNil(ns.Calculator:EvaluateCalculatorExpression("4gs + 1"))
end

local pass, fail, failures = H.runSuite("Calculator", tests)
return { pass = pass, fail = fail, failures = failures }
