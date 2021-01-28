#!/bin/bash

ipaddr=$(hostname -I | awk ' { print $1 } ')

printf '{
 "audit": {
  "max-size": 134217728, 
  "expire-hours": 1, 
  "mode": "N", 
  "audit-dir": "/var/lib/radon/audit"
 }, 
 "monitor": {
  "monitor-address": "%s:13308"
 }, 
 "proxy": {
  "endpoint": ":3306", 
  "load-balance": 1, 
  "stream-buffer-size": 33554432, 
  "max-join-rows": 100000, 
  "meta-dir": "/var/lib/radon/metainfo", 
  "query-timeout": 0, 
  "ddl-timeout": 36000000, 
  "twopc-enable": true, 
  "max-connections": 1024, 
  "peer-address": "%s:8080", 
  "max-result-size": 4294967296
 }, 
 "router": {
  "slots-readonly": 4096, 
  "blocks-readonly": 256
 }, 
 "scatter": {
  "xa-check-dir": "/var/lib/radon/xacheck"
 }, 
 "log": {
  "level": "INFO"
 }
}' $ipaddr $ipaddr > /radon/radon.json

chown -R radon:radon /radon/radon.json

exec "$@"
