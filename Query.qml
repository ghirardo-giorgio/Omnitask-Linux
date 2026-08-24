pragma Singleton

import QtQuick
import Quickshell

// Structured answers about the running system, for the MCP server.
//
// This file is written in English on purpose, unlike the rest of the project:
// everything it produces is read by a language model, and the tool surface,
// the JSON keys and the wording of the caveats are all part of that model's
// prompt. Keeping the code in the same language as its output makes the two
// easy to keep in step.
//
// Everything here is READ-ONLY. Mutating Home Assistant goes through a
// separate entry point (see haAct in shell.qml), so a question can never
// change anything by accident.
//
// Why answers are built here rather than in Python: CPU, disk and network are
// differences between two samples, and the reverse-DNS and geolocation caches
// fill in asynchronously — a freshly spawned script sees none of it. Measured
// on a cold start, the first sample carried 0 of 7 peers with a country and 0
// with a hostname; only by the third had they filled in. The running dashboard
// already holds all of it warm.
Singleton {
    id: root

    // The IPC socket drops the reply — with a socket error, not a truncation —
    // somewhere above 128 KiB, and gets flaky before that. Measured: 128 KiB
    // reliable, 150 KB succeeded once in three tries, 200 KB never. This cap
    // sits far below that, which is where a model's context window wants it
    // anyway.
    readonly property int maxResponseBytes: 32768

    // How many rows any single list may carry. Beyond this the answer reports
    // what it left out rather than growing: the full process table is about
    // 124,000 characters, roughly 31,000 tokens, and almost all of it is noise
    // for any given question.
    readonly property int maxRows: 40

    // ---------------------------------------------------------------- entry

    // Single JSON string in, single JSON string out. One shape covers every
    // tool, and it avoids depending on multi-argument IpcHandler support.
    function answer(request: string): string {
        var query;
        try {
            query = JSON.parse(request || "{}");
        } catch (error) {
            return root.fail("request is not valid JSON: " + error);
        }

        const topic = query.topic || "";
        var payload;

        try {
            switch (topic) {
            case "capabilities":
                payload = root.capabilities();
                break;
            case "overview":
                payload = root.overview();
                break;
            case "connections":
                payload = root.connections(query);
                break;
            case "top":
                payload = root.top(query);
                break;
            case "process":
                payload = root.process(query);
                break;
            case "home_assistant":
                payload = root.homeAssistant(query);
                break;
            case "health":
                payload = root.health();
                break;
            case "trend":
                payload = root.trend(query);
                break;
            default:
                return root.fail("unknown topic: " + (topic || "(none)"));
            }
        } catch (error) {
            return root.fail("failed to answer '" + topic + "': " + error);
        }

        payload.topic = topic;
        payload.sampled_at = new Date().toISOString();
        payload.interval_ms = Settings.procInterval;
        return root.clamp(payload);
    }

    function fail(message: string): string {
        return JSON.stringify({
            ok: false,
            error: message
        });
    }

    // Last line of defence. Every builder caps its own lists, so going over is
    // a bug rather than an expected case — but a reply that trips the socket
    // limit fails the whole tool call, and losing detail beats losing the
    // answer.
    function clamp(payload: var): string {
        var text = JSON.stringify(payload);
        if (text.length <= root.maxResponseBytes)
            return text;
        return JSON.stringify({
            ok: false,
            topic: payload.topic,
            error: "answer too large (" + text.length + " bytes); narrow the question",
            hint: "pass a program name, a country, or a smaller limit"
        });
    }

    // ------------------------------------------------------------- caveats

    // What the model must know before it trusts anything else here. These are
    // the ways an answer can be confidently wrong rather than merely missing,
    // so they travel attached to the answers themselves, not only in
    // `capabilities`.
    function caveats(): var {
        const out = [];

        if (Processes.orphanConns > 0)
            out.push({
                what: "unattributed_connections",
                detail: Processes.orphanConns + " established connections could not be matched to a process, so they are missing from every per-process answer. They belong to root or to another user.",
                fix: Processes.connFix
            });

        if (Processes.geoError.length > 0)
            out.push({
                what: "stale_geolocation_database",
                detail: Processes.geoError,
                fix: Processes.geoFix
            });

        if (!Processes.netAvailable)
            out.push({
                what: "no_per_process_traffic",
                detail: Processes.netError
            });

        if (!Processes.gpuAvailable)
            out.push({
                what: "no_per_process_gpu",
                detail: Processes.gpuError
            });

        // Without this, `health` comes back with no complaint about any disk,
        // which reads exactly like "the disks are fine" — the one way this
        // answer can be confidently wrong instead of merely thin.
        if ((SystemStats.health ?? ({})).smart)
            out.push({
                what: "disk_health_unreadable",
                detail: "SMART could not be read, so no disk can be reported as failing even if it is.",
                fix: root.smartTroubleText[SystemStats.health.smart] ?? SystemStats.health.smart
            });

        if (Processes.vpnExit !== null)
            out.push({
                what: "vpn_active",
                detail: "Traffic leaves through " + Processes.vpnExit.iface + " and reaches the internet from " + root.placeOf(Processes.vpnExit) + ", which is not where this machine physically is."
            });

        return out;
    }

    function placeOf(where: var): string {
        if (!where)
            return "an unknown location";
        const city = where.city && where.city.length > 0 ? where.city + ", " : "";
        return city + (where.country || "an unknown country");
    }

    // ------------------------------------------------------- capabilities

    function capabilities(): var {
        return {
            ok: true,
            dashboard: "running",
            // Answers come from live differential samples; this is how far
            // apart they are.
            sample_interval_ms: Settings.procInterval,
            processes_known: Processes.all.length,
            per_process_traffic: Processes.netAvailable,
            per_process_gpu: Processes.gpuAvailable,
            connection_attribution: Processes.orphanConns === 0 ? "complete" : "partial",
            home_assistant: HomeAssistant.online ? "online" : (HomeAssistant.token.length === 0 ? "not configured" : "unreachable"),
            home_assistant_entities: Object.keys(HomeAssistant.states).length,
            vpn: Processes.vpnExit === null ? null : {
                interface: Processes.vpnExit.iface,
                exits_from: root.placeOf(Processes.vpnExit),
                country: Processes.vpnExit.country || "",
                iso: Processes.vpnExit.iso || ""
            },
            primary_interface: SystemStats.net.iface,
            interfaces_carrying_traffic: SystemStats.net.interfaces ?? [],
            caveats: root.caveats()
        };
    }

    // ---------------------------------------------------------- overview

    function overview(): var {
        const cores = SystemStats.cores.length;
        return {
            ok: true,
            cpu: {
                // The dashboard shows both: the per-thread figure is the one
                // people mean by "how busy is the CPU".
                busy_percent: Math.round(SystemStats.cpu * 10) / 10,
                threads: cores,
                model: SystemStats.cpuName
            },
            memory: {
                used_bytes: SystemStats.mem.used,
                total_bytes: SystemStats.mem.total,
                used_percent: Math.round(SystemStats.mem.pct * 10) / 10,
                swap_used_bytes: SystemStats.mem.swapUsed
            },
            gpu: SystemStats.gpu === null ? null : {
                busy_percent: SystemStats.gpu.util ?? null,
                vram_used_bytes: SystemStats.gpu.memUsed ?? null,
                vram_total_bytes: SystemStats.gpu.memTotal ?? null,
                celsius: SystemStats.gpu.temp ?? null,
                model: SystemStats.gpuName
            },
            network: {
                interface: SystemStats.net.iface,
                rx_bytes_per_second: SystemStats.net.rx,
                tx_bytes_per_second: SystemStats.net.tx
            },
            power_watts: SystemStats.power ? SystemStats.power.total : null,
            // These two come from sysmon's own ranking, which groups by
            // program name and carries no pid — ask `top` for processes.
            busiest: {
                cpu: (SystemStats.topCpu ?? []).slice(0, 3).map(p => ({
                            name: p.name,
                            percent_of_all_threads: p.pct
                        })),
                memory: (SystemStats.topRam ?? []).slice(0, 3).map(p => ({
                            name: p.name,
                            resident_bytes: p.bytes
                        }))
            },
            caveats: root.caveats()
        };
    }

    // -------------------------------------------------------- connections

    // Who a program is talking to, and where those machines are.
    //
    // Two things this must not flatten. A program is many processes — 36 are
    // called "brave" on this machine and exactly one holds the connections —
    // so the answer aggregates by name. And a public address the database
    // cannot place is not the same as one that resolved to nothing: anycast
    // CDN ranges genuinely have no single location, and silently dropping them
    // turned "4 of 7 peers are a CDN with no location" into the much more
    // confident, much wronger "Brave connects to the United States".
    function connections(query: var): var {
        const wanted = (query.program || "").toLowerCase();
        const country = (query.country || "").toLowerCase();

        const matched = Processes.all.filter(p => wanted.length === 0 || p.name.toLowerCase().includes(wanted) || p.cmdline.toLowerCase().includes(wanted));

        const countries = ({});
        const rows = [];
        var loopback = 0;
        var lan = 0;
        var unlocatable = 0;
        var withConnections = 0;

        for (const process of matched) {
            const peers = process.peers ?? [];
            if (peers.length > 0)
                withConnections++;

            for (const peer of peers) {
                if (peer.scope === "loopback") {
                    loopback++;
                    continue;
                }
                if (peer.scope === "lan") {
                    lan++;
                    continue;
                }

                const named = peer.country || "";
                if (named.length === 0) {
                    unlocatable++;
                    continue;
                }
                if (country.length > 0 && named.toLowerCase() !== country)
                    continue;

                const seen = countries[named];
                if (seen)
                    seen.peers++;
                else
                    countries[named] = {
                        name: named,
                        iso: peer.iso ?? "",
                        peers: 1
                    };

                if (rows.length < root.maxRows)
                    rows.push({
                        process: process.name,
                        pid: process.pid,
                        ip: peer.ip,
                        hostname: peer.name ?? "",
                        port: peer.port,
                        country: named,
                        // 20 km is a neighbourhood; 1000 km is the national
                        // centroid, where many unrelated addresses pile up.
                        accuracy_km: peer.radius ?? null,
                        approximate: peer.approx ?? false,
                        interface: peer.iface ?? ""
                    });
            }
        }

        const total = rows.length;
        const out = {
            ok: true,
            program: query.program || "(all programs)",
            processes_matched: matched.length,
            processes_with_connections: withConnections,
            countries: Object.keys(countries).sort().map(name => countries[name]),
            peers: rows,
            peers_shown: Math.min(total, root.maxRows),
            loopback_peers: loopback,
            lan_peers: lan,
            caveats: root.caveats()
        };

        if (unlocatable > 0)
            out.unlocatable_peers = {
                count: unlocatable,
                reason: "public addresses the geolocation database has no position for, typically anycast CDN ranges. They are real connections; they just have no single place."
            };

        if (country.length > 0)
            out.filtered_by_country = query.country;

        return out;
    }

    // ---------------------------------------------------------------- top

    function top(query: var): var {
        const resource = (query.resource || "cpu").toLowerCase();
        const limit = Math.min(Math.max(parseInt(query.limit) || 10, 1), root.maxRows);

        const keys = ({
                cpu: "cpu",
                memory: "rss",
                gpu: "gpu",
                disk: "io",
                network: "net"
            });
        const key = keys[resource];
        if (!key)
            return {
                ok: false,
                error: "unknown resource: " + resource,
                valid: Object.keys(keys)
            };

        const units = ({
                cpu: "percent_of_one_thread",
                memory: "bytes_resident",
                gpu: "percent",
                disk: "bytes_per_second",
                network: "bytes_per_second"
            });

        const ranked = Processes.all.filter(p => (p[key] ?? 0) > 0).sort((a, b) => (b[key] ?? 0) - (a[key] ?? 0)).slice(0, limit);

        return {
            ok: true,
            resource: resource,
            unit: units[resource],
            processes: ranked.map(p => ({
                        name: p.name,
                        pid: p.pid,
                        user: p.user ?? "",
                        value: p[key] ?? 0
                    })),
            shown: ranked.length,
            total_with_usage: Processes.all.filter(p => (p[key] ?? 0) > 0).length,
            caveats: root.caveats()
        };
    }

    // ------------------------------------------------------------ process

    // Everything about one program, with its processes added up. Asking by
    // name is the common case and it almost always spans many pids.
    function process(query: var): var {
        const pid = parseInt(query.pid) || 0;
        const wanted = (query.name || "").toLowerCase();

        const matched = pid > 0 ? Processes.all.filter(p => p.pid === pid) : Processes.all.filter(p => p.name.toLowerCase().includes(wanted));

        if (matched.length === 0)
            return {
                ok: false,
                error: "no process matches " + (pid > 0 ? "pid " + pid : "name '" + (query.name || "") + "'")
            };

        var cpu = 0;
        var rss = 0;
        var io = 0;
        var net = 0;
        var conns = 0;
        for (const p of matched) {
            cpu += p.cpu ?? 0;
            rss += p.rss ?? 0;
            io += p.io ?? 0;
            net += p.net ?? 0;
            conns += p.conns ?? 0;
        }

        const heaviest = matched.slice().sort((a, b) => (b.cpu ?? 0) - (a.cpu ?? 0)).slice(0, 10);

        return {
            ok: true,
            matched: query.name || String(pid),
            processes: matched.length,
            totals: {
                cpu_percent_of_one_thread: Math.round(cpu * 10) / 10,
                memory_resident_bytes: rss,
                disk_bytes_per_second: io,
                network_bytes_per_second: net,
                established_connections: conns
            },
            users: Array.from(new Set(matched.map(p => p.user ?? ""))).filter(u => u.length > 0),
            busiest_processes: heaviest.map(p => ({
                        name: p.name,
                        pid: p.pid,
                        user: p.user ?? "",
                        state: p.state,
                        nice: p.nice ?? 0,
                        cpu_percent_of_one_thread: p.cpu ?? 0,
                        memory_resident_bytes: p.rss ?? 0,
                        command: (p.cmdline || "").slice(0, 160)
                    })),
            caveats: root.caveats()
        };
    }

    // ----------------------------------------------------- home assistant

    function homeAssistant(query: var): var {
        if (HomeAssistant.token.length === 0)
            return {
                ok: false,
                error: "Home Assistant is not configured (no token in ~/.config/quickshell/home-assistant.json)"
            };

        if (!HomeAssistant.online)
            return {
                ok: false,
                error: "Home Assistant is unreachable: " + (HomeAssistant.lastError || "no response from " + HomeAssistant.baseUrl)
            };

        const domain = (query.domain || "").toLowerCase();
        const wanted = (query.query || "").toLowerCase();

        const all = Object.keys(HomeAssistant.states).sort();
        const matched = all.filter(id => {
            if (domain.length > 0 && id.split(".")[0] !== domain)
                return false;
            if (wanted.length === 0)
                return true;
            return id.toLowerCase().includes(wanted) || HomeAssistant.friendlyName(id).toLowerCase().includes(wanted);
        });

        const domains = ({});
        for (const id of all) {
            const key = id.split(".")[0];
            domains[key] = (domains[key] ?? 0) + 1;
        }

        return {
            ok: true,
            url: HomeAssistant.baseUrl,
            // Polled on a timer rather than pushed, so a value can be up to
            // one interval behind whatever the device is actually doing.
            poll_interval_ms: Settings.haPollInterval,
            entities_total: all.length,
            domains: domains,
            entities: matched.slice(0, root.maxRows).map(id => ({
                        entity_id: id,
                        name: HomeAssistant.friendlyName(id),
                        state: HomeAssistant.state(id),
                        unit: HomeAssistant.unit(id)
                    })),
            entities_matched: matched.length,
            entities_shown: Math.min(matched.length, root.maxRows)
        };
    }

    // ------------------------------------------------------------- health

    // Why the SMART data below carries a verdict instead of a pile of
    // counters.
    //
    // A drive that is done for says so in more than one way, and the one
    // everybody checks first — SMART's own pass/fail — is the least sensitive
    // of them, because the thresholds behind it are chosen by the
    // manufacturer and sit a long way out. Both halves of that were measured
    // on this machine: one NVMe reports pass/fail = FAILED with its spare pool
    // at 23% and 28,911 media errors, while a SATA SSD with an unreadable
    // pending sector still reports PASSED. Handing over the pass/fail alone
    // would have called the second one healthy, and handing over the raw
    // attribute table would have left the reading to whoever asked.
    //
    // Hence two levels, and what separates them is who is making the claim:
    //   failing — the drive itself says it is failing.
    //   warning — the drive still says it is fine, but its counters carry the
    //             marks that come before failure.
    readonly property var smartFlagText: ({
            spare_below_threshold: "its pool of spare blocks, the ones it swaps in for failed ones, has fallen below the threshold",
            media_read_only: "it has put itself into read-only mode, which is what a drive does when it can no longer be written to safely",
            reliability_degraded: "it reports its own reliability as degraded",
            temperature_above_or_below_threshold: "it is outside its safe temperature range",
            volatile_memory_backup_failed: "its power-loss protection has failed, so a sudden power cut can lose writes it has already acknowledged",
            persistent_memory_region_unreliable: "its persistent memory region is unreliable"
        })

    readonly property var smartTroubleText: ({
            missing: "smartctl is not installed, so nothing can be read about disk health.",
            denied: "smartctl needs privileges this dashboard does not have. Grant exactly the two read-only commands it uses with: sudo install -m 0440 -o root -g root scripts/quickshell-smart.sudoers /etc/sudoers.d/quickshell-smart",
            failed: "smartctl could not be run.",
            empty: "the drive replied but carried no health data. USB enclosures commonly do not pass SMART through to the disk behind them."
        })

    // One disk's health, as a judgement plus the numbers it rests on.
    function smartOf(disk: var): var {
        const smart = disk.smart ?? ({});

        if (smart.error !== undefined)
            return {
                readable: false,
                verdict: "unknown",
                why: root.smartTroubleText[smart.error] ?? ("disk health could not be read: " + smart.error)
            };

        const counters = ({});
        const record = (key, value) => {
            if (value !== undefined && value !== null)
                counters[key] = value;
        };

        record("reallocated_sectors", smart.realloc);
        record("pending_sectors", smart.pending);
        record("offline_uncorrectable_sectors", smart.offline);
        record("reported_uncorrectable_errors", smart.uncorrect);
        record("interface_crc_errors", smart.crc);
        record("media_errors", smart.errors);
        record("wear_percent", smart.used);
        record("spare_percent", smart.spare);
        record("power_on_hours", smart.hours);
        record("bytes_written", smart.written);

        if (Object.keys(counters).length === 0 && smart.passed === undefined)
            return {
                readable: false,
                verdict: "unknown",
                why: "no SMART data arrived for this disk."
            };

        const reasons = [];
        var failing = false;
        var worrying = false;

        if (smart.passed === false) {
            failing = true;
            const flags = (smart.flags ?? []).map(f => root.smartFlagText[f] ?? f);
            reasons.push(flags.length > 0 ? "The drive's own health self-assessment has FAILED: " + flags.join("; ") + "." : "The drive's own health self-assessment has FAILED.");
        }

        // Sectors the drive tried to read, could not, and has not yet been
        // able to move: the single strongest predictor of a drive about to go,
        // and it does not move the pass/fail flag at all.
        if ((smart.pending ?? 0) > 0) {
            worrying = true;
            reasons.push(smart.pending + " sector(s) are pending: the drive could not read them and has not managed to relocate them. Whatever file sits there is already unreadable.");
        }

        if ((smart.offline ?? 0) > 0) {
            worrying = true;
            reasons.push(smart.offline + " sector(s) are uncorrectable offline.");
        }

        if ((smart.uncorrect ?? 0) > 0) {
            worrying = true;
            reasons.push(smart.uncorrect + " error(s) the drive's own correction could not repair.");
        }

        if ((smart.realloc ?? 0) > 0) {
            worrying = true;
            reasons.push(smart.realloc + " sector(s) have already been replaced with spares. A handful is normal wear; a count that keeps climbing is not.");
        }

        if ((smart.errors ?? 0) > 0) {
            worrying = true;
            reasons.push(smart.errors + " media error(s) since the drive was made.");
        }

        if (smart.spare !== undefined && smart.spare !== null && smart.spare < 50) {
            worrying = true;
            reasons.push("Only " + smart.spare + "% of its spare blocks are left.");
        }

        if ((smart.used ?? 0) >= 90) {
            worrying = true;
            reasons.push("It has used " + smart.used + "% of its rated write endurance.");
        }

        // A cable problem, not a dying disk — and it counts up forever, so an
        // old drive collects a few without anything being wrong today. Said,
        // because it explains transfer errors; not counted against the disk.
        if ((smart.crc ?? 0) > 0)
            reasons.push(smart.crc + " interface CRC error(s): these come from the cable or the port, not from the disk itself, and they never reset.");

        return {
            readable: true,
            verdict: failing ? "failing" : (worrying ? "warning" : "ok"),
            self_assessment: smart.passed === undefined ? "not reported" : (smart.passed ? "passed" : "FAILED"),
            reasons: reasons,
            counters: counters
        };
    }

    function health(): var {
        const stats = SystemStats.health ?? ({});
        const hottest = (SystemStats.temps ?? []).slice().filter(t => t.temp !== null && t.temp !== undefined).sort((a, b) => b.temp - a.temp).slice(0, 8);

        const disks = (SystemStats.disks ?? []).slice(0, root.maxRows).map(d => ({
                    name: d.name,
                    model: d.model,
                    total_bytes: d.total,
                    used_bytes: d.used,
                    used_percent: d.pct,
                    rotational: d.rotational,
                    health: root.smartOf(d)
                }));

        const trouble = stats.smart ?? "";

        return {
            ok: true,
            uptime_seconds: stats.uptime ?? null,
            oom_kills_since_boot: stats.oomKills ?? null,
            oom_kills_since_dashboard_started: stats.oomSinceStart ?? null,
            network_errors: stats.net ?? null,
            // Whether disk health could be read at all. Empty means it could:
            // the per-disk verdicts below are then worth trusting.
            smart_access: trouble.length === 0 ? "ok" : trouble,
            // The answer to "is a disk failing?", so it does not have to be
            // reassembled from the list every time.
            disks_failing: disks.filter(d => d.health.verdict === "failing").map(d => d.name + " (" + d.model + ")"),
            disks_needing_attention: disks.filter(d => d.health.verdict === "warning").map(d => d.name + " (" + d.model + ")"),
            temperatures_celsius: hottest.map(t => ({
                        sensor: t.label || t.key,
                        chip: t.chip,
                        disk: t.disk || "",
                        celsius: t.temp,
                        critical_at: t.crit
                    })),
            // "some" is the share of time at least one task was stalled
            // waiting for the resource; "full" is when everything was.
            pressure_percent: SystemStats.pressure ?? null,
            power_watts: SystemStats.power ?? null,
            disks: disks,
            caveats: root.caveats()
        };
    }

    // -------------------------------------------------------------- trend

    // History the dashboard has kept since it started. Answers "is this
    // growing?", which a single instantaneous reading cannot.
    function trend(query: var): var {
        const metric = (query.metric || "").toLowerCase();

        const series = ({
                cpu: {
                    values: SystemStats.cpuHistory,
                    unit: "percent"
                },
                memory: {
                    values: SystemStats.memHistory,
                    unit: "percent"
                },
                gpu: {
                    values: SystemStats.gpuHistory,
                    unit: "percent"
                },
                network_in: {
                    values: SystemStats.netRxHistory,
                    unit: "bytes_per_second"
                },
                network_out: {
                    values: SystemStats.netTxHistory,
                    unit: "bytes_per_second"
                },
                heart_rate: {
                    values: Fitbit.values,
                    unit: "bpm",
                    // Il battito non e' campionato come gli altri: un punto al
                    // minuto invece che ogni `procInterval`, e con dei buchi
                    // dove il braccialetto non ha mandato niente.
                    intervalMs: 60000,
                    gaps: true
                }
            });

        const found = series[metric];
        if (!found)
            return {
                ok: false,
                error: "unknown metric: " + (metric || "(none)"),
                valid: Object.keys(series)
            };

        // I buchi si tolgono prima di contare: un `null` sommato diventa zero,
        // e un minuto senza dati abbasserebbe la media come se il cuore si
        // fosse fermato. Quanti erano pero' si dice, perche' e' un fatto vero
        // — «il braccialetto era via per venti minuti» — e non un dettaglio.
        const raw = (found.values ?? []).slice();
        const values = found.gaps ? raw.filter(v => v !== null && isFinite(v)) : raw;
        const gaps = raw.length - values.length;

        if (values.length === 0)
            return {
                ok: false,
                error: "no history yet for " + metric
            };

        var sum = 0;
        var min = values[0];
        var max = values[0];
        for (const v of values) {
            sum += v;
            if (v < min)
                min = v;
            if (v > max)
                max = v;
        }

        // First half against second half: enough to tell a climb from noise
        // without shipping the whole series.
        const half = Math.floor(values.length / 2);
        const early = values.slice(0, half);
        const late = values.slice(half);
        const mean = list => list.length === 0 ? 0 : list.reduce((a, b) => a + b, 0) / list.length;

        return {
            ok: true,
            metric: metric,
            unit: found.unit,
            samples: values.length,
            covers_seconds: Math.round(raw.length * (found.intervalMs ?? Settings.procInterval) / 1000),
            gaps: gaps,
            latest: values[values.length - 1],
            minimum: min,
            maximum: max,
            average: Math.round(sum / values.length * 100) / 100,
            first_half_average: Math.round(mean(early) * 100) / 100,
            second_half_average: Math.round(mean(late) * 100) / 100,
            note: "History starts when the dashboard starts; it is not persisted across restarts."
        };
    }

    // ------------------------------------------------- home assistant act

    // The only path that changes anything. Kept apart from `answer` so no
    // read can ever mutate.
    function act(request: string): string {
        var command;
        try {
            command = JSON.parse(request || "{}");
        } catch (error) {
            return root.fail("request is not valid JSON: " + error);
        }

        if (HomeAssistant.token.length === 0)
            return root.fail("Home Assistant is not configured");
        if (!HomeAssistant.online)
            return root.fail("Home Assistant is unreachable");

        const entity = command.entity_id || "";
        if (entity.length === 0)
            return root.fail("entity_id is required");
        if (HomeAssistant.states[entity] === undefined)
            return root.fail("unknown entity: " + entity);

        const before = HomeAssistant.state(entity);

        if (command.action === "toggle") {
            HomeAssistant.toggleEntity(entity);
        } else if (command.action === "call") {
            const domain = command.domain || entity.split(".")[0];
            const service = command.service || "";
            if (service.length === 0)
                return root.fail("service is required for action 'call'");
            HomeAssistant.callService(domain, service, entity, command.data ?? ({}));
        } else {
            return root.fail("unknown action: " + (command.action || "(none)") + " (use 'toggle' or 'call')");
        }

        return JSON.stringify({
            ok: true,
            entity_id: entity,
            action: command.action,
            state_before: before,
            // The call is asynchronous and the poll is on a timer, so the new
            // state is not readable yet. Saying so beats reporting the old one
            // as if it were the result.
            note: "Accepted. Re-read the entity after " + Settings.haPollInterval + " ms to see the resulting state."
        });
    }
}
