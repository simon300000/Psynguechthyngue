// SPDX-License-Identifier: MIT

package main

import (
	"encoding/json"
	"fmt"
	"os"
)

func main() {
	if len(os.Args) < 3 || len(os.Args) > 5 {
		fmt.Fprintln(os.Stderr, "usage: syncthing_contract_check preflight|verify|json|field|upstream GOCORE [FIELD|DIRECTORY ZIP]")
		os.Exit(64)
	}
	mode, coreDir := os.Args[1], os.Args[2]
	requireTree := mode != "preflight" && mode != "upstream"
	contract, err := loadSyncthingSourceContract(coreDir, requireTree)
	if err != nil {
		fmt.Fprintln(os.Stderr, "Syncthing source contract:", err)
		os.Exit(1)
	}
	switch mode {
	case "preflight", "verify":
		return
	case "json":
		if len(os.Args) != 3 {
			fmt.Fprintln(os.Stderr, "json mode does not accept a field")
			os.Exit(64)
		}
		encoder := json.NewEncoder(os.Stdout)
		encoder.SetEscapeHTML(false)
		encoder.SetIndent("", "  ")
		if err := encoder.Encode(contract.Lock); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	case "field":
		if len(os.Args) != 4 {
			fmt.Fprintln(os.Stderr, "field mode requires a field")
			os.Exit(64)
		}
		values := map[string]string{
			"modulePath":        contract.Lock.ModulePath,
			"moduleVersion":     contract.Lock.ModuleVersion,
			"moduleCommit":      contract.Lock.ModuleCommit,
			"moduleSum":         contract.Lock.ModuleSum,
			"localReplacePath":  contract.Lock.LocalReplacePath,
			"patchPath":         contract.Lock.PatchPath,
			"patchSHA256":       contract.PatchSHA256,
			"patchedTreeSHA256": contract.TreeSHA256,
		}
		value, ok := values[os.Args[3]]
		if !ok {
			fmt.Fprintln(os.Stderr, "unknown Syncthing source contract field")
			os.Exit(64)
		}
		fmt.Println(value)
	case "upstream":
		if len(os.Args) != 5 {
			fmt.Fprintln(os.Stderr, "upstream mode requires a module directory and zip")
			os.Exit(64)
		}
		if err := verifyPristineSyncthingModule(contract, os.Args[3], os.Args[4]); err != nil {
			fmt.Fprintln(os.Stderr, "Syncthing upstream contract:", err)
			os.Exit(1)
		}
	default:
		fmt.Fprintln(os.Stderr, "unsupported Syncthing source contract mode")
		os.Exit(64)
	}
}
