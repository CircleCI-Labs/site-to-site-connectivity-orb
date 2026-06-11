#!/bin/bash

touch "${TMPDIR:-/tmp}/tunnel-proxy.log"
tail -f "${TMPDIR:-/tmp}/tunnel-proxy.log"
