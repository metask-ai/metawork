// One async budget for every renderer test. configure() writes a single
// process-wide config inside @testing-library/dom, and node --test gives each
// test file its own process, so the budget has to be established once per
// file. Importing this module is what establishes it, and re-exporting the
// library is what makes the import unavoidable: a renderer test cannot reach
// render(), screen or waitFor without passing through here.
//
// A longer budget costs a passing test nothing, because every async utility
// returns the moment its condition holds. The 1 second library default
// silently turned each wait into an assumption about machine load, which is
// how a correct assertion still failed once the whole suite ran in parallel.
// 5 seconds bounds a broken wait instead of a busy one. Tests that mean to
// bound the application's own timing still say so with an explicit timeout.
import { configure } from "@testing-library/react";

export * from "@testing-library/react";

configure({ asyncUtilTimeout: 5000 });
