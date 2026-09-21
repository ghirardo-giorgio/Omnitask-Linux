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
            payload = root.build(query, topic);
        } catch (error) {
            return root.fail("failed to answer '" + topic + "': " + error);
        }

        if (payload === null)
            return root.fail("unknown topic: " + (topic || "(none)"));

        payload.topic = topic;
        payload.sampled_at = new Date().toISOString();
        payload.interval_ms = Settings.procInterval;
        return root.clamp(payload);
    }

    // The switch, kept apart from answer() because `bundle` needs a topic as
    // an object rather than a string it has to parse back. `null` means the
    // topic means nothing here — an error the caller words, since answer()
    // and bundle() say it differently.
    function build(query: var, topic: string): var {
        switch (topic) {
        case "capabilities":
            return root.capabilities();
        case "overview":
            return root.overview();
        case "connections":
            return root.connections(query);
        case "top":
            return root.top(query);
        case "process":
            return root.process(query);
        case "home_assistant":
            return root.homeAssistant(query);
        case "health":
            return root.health();
        case "trend":
            return root.trend(query);
        case "series":
            return root.series(query);
        case "bundle":
            return root.bundle(query);
        case "pet":
            return root.pet();
        case "pressure":
            return root.pressureReport();
        }

        return null;
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
        // An explicit list wins over any filter: a client that already knows
        // which entities it draws should not have to describe them.
        const asked = Array.isArray(query.entities) ? query.entities : null;

        const all = Object.keys(HomeAssistant.states).sort();
        const matched = asked !== null ? all.filter(id => asked.includes(id)) : all.filter(id => {
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
            entities_shown: Math.min(matched.length, root.maxRows),
            // The entities the user picked in the dashboard's own options,
            // whether or not they were asked for here. A second screen
            // showing this machine should show the same ones without the
            // choice having to be made twice.
            chosen: Settings.haEntities.slice(),
            // Of those, the ones the user asked to see as a bare figure.
            chosen_without_chart: Settings.haNoChart.slice()
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

    // ------------------------------------------------------------- series

    // The points themselves, not statistics about them. `trend` answers "is
    // this growing?"; this one is what a client draws. It exists for a client
    // that keeps a chart on screen — the phone app — which without the arrays
    // would have to wait one sample at a time for a minute before its graph
    // said anything.
    //
    // `metrics` is required and there is no "everything": every sensor and
    // every disk at once goes past the 32 KiB ceiling, and whoever is drawing
    // already knows what they are drawing.
    function series(query: var): var {
        const wanted = query.metrics ?? [];
        if (!Array.isArray(wanted) || wanted.length === 0)
            return {
                ok: false,
                error: "series needs a non-empty `metrics` array",
                valid: root.seriesNames()
            };

        const out = ({});
        const unknown = [];

        for (const name of wanted) {
            const found = root.seriesOf(String(name));
            if (found === null) {
                unknown.push(name);
                continue;
            }
            out[name] = found;
        }

        return {
            ok: true,
            // Sampling period of the system series. `heart` and the Home
            // Assistant ones carry their own, because they are not sampled by
            // sysmon at all.
            length: SystemStats.historyLength,
            series: out,
            unknown_metrics: unknown,
            note: "History starts when the dashboard starts; it is not persisted across restarts."
        };
    }

    // The fixed names. The three prefixed families are open-ended — one
    // sensor, one disk and one Home Assistant entity each — so they are named
    // by shape instead of being listed.
    function seriesNames(): var {
        return ["cpu", "memory", "gpu", "vram", "net_rx", "net_tx", "power_cpu", "power_gpu", "psi_cpu", "psi_io", "psi_mem", "freq", "heart", "temp:<sensor key>", "disk_read:<device>", "disk_write:<device>", "ha:<entity_id>"];
    }

    // One series, or null if the name means nothing here.
    //
    // `max` is the full-scale value the dashboard draws this series against,
    // and it travels with the values because a client cannot work it out: a
    // network chart is scaled against the busiest of download and upload
    // together (see SystemStats.netScale), and a temperature against that
    // sensor's own critical point rather than 100.
    //
    // `color` is whatever the user picked on the desktop
    // (Settings.colorFor), so the same series is the same colour on both
    // screens without the palette being written down twice.
    function seriesOf(name: string): var {
        const cut = name.indexOf(":");
        const family = cut < 0 ? name : name.slice(0, cut);
        const rest = cut < 0 ? "" : name.slice(cut + 1);

        if (family === "temp") {
            const history = (SystemStats.tempHistory ?? ({}))[rest];
            if (history === undefined)
                return null;
            const sensor = SystemStats.sensor(rest);
            return root.serie(history, "celsius", SystemStats.tempLimit(sensor), "temp:" + rest, "#f0883e");
        }

        if (family === "disk_read" || family === "disk_write") {
            const history = (SystemStats.diskHistory ?? ({}))[rest];
            if (history === undefined)
                return null;
            const read = family === "disk_read";
            // Both directions share one full scale, or a quiet disk's writes
            // would tower over its reads.
            const scale = Math.max(1048576, ...(history.read ?? []), ...(history.write ?? []));
            return root.serie(read ? history.read : history.write, "bytes_per_second", scale, read ? "diskRead" : "diskWrite", read ? "#58a6ff" : "#db6d28");
        }

        if (family === "ha") {
            const history = (HomeAssistant.history ?? ({}))[rest];
            if (history === undefined)
                return null;
            // Whatever the entity itself calls its unit: "%", "W", "°C". It
            // is the entity's business, not ours, and without it a client has
            // a line and no idea what it measures.
            const state = (HomeAssistant.states ?? ({}))[rest];
            const measure = state && state.attributes ? (state.attributes.unit_of_measurement ?? "") : "";
            const serie = root.serie(history, measure, 0, "ha:" + rest, "#58a6ff");
            // Home Assistant's own recorder, not sysmon's ring buffer: five
            // minutes a point, and the window starts where the download did.
            serie.interval_ms = HomeAssistant.historyBucketMinutes * 60000;
            serie.starts_at = new Date(HomeAssistant.historyStart).toISOString();
            serie.autoscale = true;
            return serie;
        }

        const gpu = SystemStats.gpu;

        switch (name) {
        case "cpu":
            return root.serie(SystemStats.cpuHistory, "percent", 100, "cpu", "#3fb950");
        case "memory":
            return root.serie(SystemStats.memHistory, "percent", 100, "ram", "#58a6ff");
        case "gpu":
            return gpu === null ? null : root.serie(SystemStats.gpuHistory, "percent", 100, "gpu", "#a371f7");
        case "vram":
            return gpu === null ? null : root.serie(SystemStats.vramHistory, "percent", 100, "vram", "#a371f7");
        case "net_rx":
            return root.serie(SystemStats.netRxHistory, "bytes_per_second", SystemStats.netScale, "netRx", "#58a6ff");
        case "net_tx":
            return root.serie(SystemStats.netTxHistory, "bytes_per_second", SystemStats.netScale, "netTx", "#db6d28");
        case "power_cpu":
        case "power_gpu":
            // Watts have no ceiling to draw against, so the dashboard scales
            // them against their own peak with a floor under it — otherwise
            // an idle machine's two watts would fill the chart. See
            // PowerChart.minScale, which is where the 60 comes from.
            if (SystemStats.power === null)
                return null;
            const cpuSide = name === "power_cpu";
            const watts = root.serie(cpuSide ? SystemStats.cpuWattHistory : SystemStats.gpuWattHistory, "watts", 0, cpuSide ? "powerCpu" : "powerGpu", cpuSide ? "#3fb950" : "#a371f7");
            watts.autoscale = true;
            watts.min_scale = 60;
            return watts;
        case "psi_cpu":
            return root.serie(SystemStats.psiCpuHistory, "percent", 100, "psiCpu", "#3fb950");
        case "psi_io":
            return root.serie(SystemStats.psiIoHistory, "percent", 100, "psiIo", "#db6d28");
        case "psi_mem":
            return root.serie(SystemStats.psiMemHistory, "percent", 100, "psiMem", "#58a6ff");
        case "freq":
            return SystemStats.freq === null ? null : root.serie(SystemStats.freqHistory, "megahertz", SystemStats.freq.max ?? 0, "freq", "#58a6ff");
        case "heart":
            const beats = root.serie(Fitbit.values, "bpm", 0, "heart", "#f85149");
            // One point a minute, and the gaps are real: nulls stay nulls so
            // the line breaks where the band was off the wrist, instead of
            // dropping to zero and drawing a cardiac arrest.
            beats.interval_ms = 60000;
            beats.gaps = true;
            beats.autoscale = true;
            return beats;
        }

        return null;
    }

    // Rounding is not cosmetic here: raw byte-per-second figures carry twelve
    // digits of float noise each, and sixty of them per series is most of the
    // reply spent on decimals nobody can see on a phone.
    function serie(values: var, unit: string, max: real, colorId: string, fallback: string): var {
        const rounded = (values ?? []).map(v => v === null || v === undefined || !isFinite(v) ? null : Math.round(v * 100) / 100);
        return {
            values: rounded,
            unit: unit,
            max: Math.round(max * 100) / 100,
            color: Settings.colorFor(colorId, fallback)
        };
    }

    // ------------------------------------------------------------- bundle

    // Several topics in one reply.
    //
    // Every question costs the caller a process — `qs ipc call` is a fork —
    // and a client refreshing six panels twice a second would spend more time
    // starting processes than reading numbers. The answers are objects inside
    // this one, which is why the switch lives in build() rather than inside
    // answer(): going through JSON.stringify and parsing it back would be a
    // string inside a string.
    function bundle(query: var): var {
        const requests = query.topics ?? [];
        if (!Array.isArray(requests) || requests.length === 0)
            return {
                ok: false,
                error: "bundle needs a non-empty `topics` array"
            };

        const answers = [];
        const dropped = [];
        // What clamp() would allow, less room for the envelope this all gets
        // wrapped in. Dropping a topic and saying so beats tripping the cap
        // and losing every answer in the batch.
        var budget = root.maxResponseBytes - 1024;

        for (const request of requests) {
            const sub = (request || ({})).topic || "";

            if (sub === "bundle") {
                dropped.push({
                    topic: sub,
                    why: "a bundle cannot contain a bundle"
                });
                continue;
            }

            var payload;
            try {
                payload = root.build(request, sub);
            } catch (error) {
                payload = {
                    ok: false,
                    error: "failed to answer '" + sub + "': " + error
                };
            }

            if (payload === null)
                payload = {
                    ok: false,
                    error: "unknown topic: " + (sub || "(none)")
                };

            payload.topic = sub;
            const cost = JSON.stringify(payload).length;

            if (cost > budget) {
                dropped.push({
                    topic: sub,
                    why: "no room left in the reply (" + cost + " bytes); ask for it on its own"
                });
                continue;
            }

            budget -= cost;
            answers.push(payload);
        }

        return {
            ok: true,
            answers: answers,
            dropped: dropped
        };
    }

    // ------------------------------------------------- home assistant act

    // The only path that changes anything. Kept apart from `answer` so no
    // read can ever mutate.
    // ------------------------------------------------------------- pressure

    // Why the machine is stalling, and whose fault it is.
    //
    // 🔴 The two halves are reported separately ON PURPOSE, because conflating
    // them is the mistake this tool exists to prevent. Per-cgroup pressure
    // measures how long a cgroup WAITED, so the top of that list is the
    // desktop shell and the editor — the victims. Whoever took the memory
    // first waits for nothing and looks innocent. `holders` is the other half:
    // who has it.
    //
    // In `holders`, `shmem_bytes` is the number that decides whether a large
    // cgroup is a problem: page cache is dropped for free when memory is
    // needed, shared memory can only be swapped, one page at a time, while
    // everything else waits.
    function pressureReport(): var {
        const psi = SystemStats.pressure;
        const holders = (SystemStats.cgroups ?? []).map(c => ({
                    name: c.comm && c.comm.length > 0 ? c.comm : c.name,
                    unit: c.name,
                    cgroup: c.path,
                    memory_bytes: c.mem,
                    // Not droppable: only swap can free it.
                    shmem_bytes: c.shmem,
                    // Droppable at no cost — a cgroup that is large only here
                    // is not a problem.
                    cache_bytes: c.cache,
                    swap_bytes: c.swap,
                    // 0 when no ceiling is set. A cgroup with a ceiling is one
                    // somebody has already tried to contain.
                    memory_high_bytes: c.high,
                    waited_percent_60s: c.waited
                }));

        return {
            ok: true,
            // Percent of the last 60 seconds spent waiting. Over ~10% the
            // machine is waiting more than it is working.
            waiting: {
                cpu: psi.cpu?.someAvg60 ?? null,
                io: psi.io?.someAvg60 ?? null,
                memory: psi.memory?.someAvg60 ?? null,
                // `full` means nobody could make progress, not just someone.
                io_full: psi.io?.fullAvg60 ?? null,
                memory_full: psi.memory?.fullAvg60 ?? null
            },
            memory: {
                total_bytes: SystemStats.mem.total,
                used_bytes: SystemStats.mem.used,
                swap_used_bytes: SystemStats.mem.swapUsed,
                swap_total_bytes: SystemStats.mem.swapTotal,
                // The two that say whether it is thrashing RIGHT NOW rather
                // than merely full: bytes per second moving in and out of
                // swap, and the page faults that had to reach the disk.
                swap_in_bytes_per_s: SystemStats.mem.swapIn,
                swap_out_bytes_per_s: SystemStats.mem.swapOut,
                major_faults_per_s: SystemStats.mem.majFaults,
                zram: SystemStats.mem.zram
            },
            holders: holders,
            caveats: [
                "holders is who HAS the memory; waited_percent_60s is who WAITED for it. They are usually different cgroups, and the second one is the victim.",
                "shmem_bytes cannot be reclaimed, only swapped. A holder whose memory is mostly shmem is the one that stalls the machine.",
                "An Electron application registers as 'app-org.chromium.Chromium-<pid>.scope'; read `name`, which is the actual command, before calling anything a browser."
            ]
        };
    }

    // ------------------------------------------------------------------ pet

    // What the pet's traits are wired to right now, plus the two catalogues a
    // caller needs in order to write one: the objects that can fall, and the
    // measures a trait can watch.
    //
    // Why this is here at all: the traits are configured through a window with
    // eight controls per row, and describing "an apple every 500 mAh of solar
    // charge" out loud is faster than driving it. The window stays the place
    // to fine-tune; this is the place to state the intent.
    function pet(): var {
        return {
            ok: true,
            traits: PetTraits.list.map(t => ({
                        id: t.id,
                        label: t.label,
                        source: t.source,
                        role: t.role,
                        value: t.value,
                        unit: t.unit,
                        // Only one of the two shapes is meaningful per trait,
                        // but both are reported: which one is in force is the
                        // first thing a caller has to see to change it.
                        drop: t.drop === null ? null : {
                            when: t.drop.when,
                            every: t.drop.every,
                            threshold: t.drop.threshold,
                            step: t.drop.step,
                            hold_minutes: Math.round(t.drop.holdMs / 60000),
                            cooldown_minutes: Math.round(t.drop.cooldownMs / 60000),
                            item: t.drop.item.id,
                            glyph: t.drop.item.glyph,
                            kind: t.drop.item.kind,
                            gift: t.drop.gift
                        },
                        wellness: t.wellness,
                        effects: t.effects
                    })),
            items: PetTraits.dropItems.map(d => ({
                        id: d.id,
                        glyph: d.glyph,
                        label: d.label,
                        kind: d.kind,
                        gift: d.gift
                    })),
            // Everything a trait may watch: the dashboard's own measures and
            // every numeric Home Assistant entity. Capped, and the count says
            // what was left out.
            sources: root.petSources(),
            sound: Settings.panelParam("pet", "sound", true) === true
        };
    }

    function petSources(): var {
        const out = [];
        for (const s of PetTraits.systemSources) {
            const source = "sys:" + s.key;
            // The reading comes along, exactly as it does for the Home
            // Assistant entities below: a caller choosing a step wants to know
            // the scale it is stepping on, and for `adbPhones` the reading IS
            // the answer to "is a phone attached right now" — null meaning
            // nobody has looked yet, which is not the same as zero.
            out.push({
                source: source,
                name: s.label,
                unit: s.unit ?? "",
                value: PetTraits.rawValue(source)
            });
        }

        const ids = Object.keys(HomeAssistant.states).filter(id => id.startsWith("sensor."));
        for (const id of ids.sort()) {
            if (out.length >= root.maxRows * 3)
                break;
            const st = HomeAssistant.states[id];
            const n = parseFloat(st.state);
            // A switch that reads on/off has no range and cannot drive a
            // trait: offering it would only produce a trait that never fires.
            if (!isFinite(n))
                continue;
            out.push({
                source: "ha:" + id,
                name: (st.attributes && st.attributes.friendly_name) || id,
                unit: (st.attributes && st.attributes.unit_of_measurement) || "",
                value: n
            });
        }
        return out;
    }

    // The pet's write entry point. Separate from `act` — which only ever
    // touches Home Assistant — for the same reason `act` is separate from
    // `answer`: one door per thing that can change.
    //
    // 🔴 It goes through PetTraits rather than writing pet-traits.json from
    // Python, and that is the whole design. The catalogue of objects, the
    // defaults for a new trait, the gift each object carries and the id
    // allocation all live there; a second copy in the MCP server would be two
    // tables to keep in step, and the first one to drift would do it silently.
    function petAct(request: string): string {
        var command;
        try {
            command = JSON.parse(request || "{}");
        } catch (error) {
            return root.fail("request is not valid JSON: " + error);
        }

        const action = command.action || "";

        if (action === "remove") {
            const id = command.id || "";
            if (!PetTraits.traits.some(t => t.id === id))
                return root.fail("unknown trait: " + (id || "(none)"));
            PetTraits.remove(id);
            return JSON.stringify({ ok: true, action: "remove", id: id });
        }

        if (action !== "set")
            return root.fail("unknown action: " + (action || "(none)") + " (use 'set' or 'remove')");

        // Either an existing trait to amend, or a source to build a new one on.
        const existing = command.id ? PetTraits.traits.find(t => t.id === command.id) : null;
        if (command.id && !existing)
            return root.fail("unknown trait: " + command.id);

        const source = command.source || (existing ? existing.source : "");
        if (!source)
            return root.fail("source is required (e.g. 'ha:sensor.solare_usb_carica' or 'sys:cpu')");
        if (!source.startsWith("ha:") && !source.startsWith("sys:"))
            return root.fail("source must start with 'ha:' or 'sys:'");

        const reading = PetTraits.rawValue(source);
        if (reading === null && !existing)
            return root.fail("that source reads nothing right now: " + source
                             + " (check the entity id; a trait on a source that never answers never fires)");

        // A new trait starts from the same defaults the window would give it,
        // so a caller that names only a source and a step still gets a
        // complete, working row.
        var trait;
        if (existing) {
            trait = JSON.parse(JSON.stringify(existing));
        } else {
            trait = PetTraits.defaultsFor(source, reading ?? 0, command.role === "wellness" ? "wellness" : "drop");
            trait.id = PetTraits.freeId(PetTraits.idFor(source));
            trait.source = source;
        }

        if (command.source)
            trait.source = command.source;
        if (typeof command.label === "string" && command.label.trim().length > 0)
            trait.label = command.label.trim().slice(0, 40);
        if (command.role === "wellness" || command.role === "drop")
            trait.role = command.role;

        if (trait.role === "drop") {
            const when = command.when || "";
            if (when) {
                if (["above", "below", "rise", "fall"].indexOf(when) < 0)
                    return root.fail("when must be one of: above, below, rise, fall");
                trait.dropWhen = when;
            }
            if (typeof command.step === "number" && isFinite(command.step)) {
                if (command.step <= 0)
                    return root.fail("step must be greater than zero");
                trait.step = command.step;
            }
            if (typeof command.threshold === "number" && isFinite(command.threshold))
                trait.threshold = command.threshold;
            if (typeof command.hold_minutes === "number" && isFinite(command.hold_minutes))
                trait.holdMinutes = Math.max(0, command.hold_minutes);
            if (typeof command.cooldown_minutes === "number" && isFinite(command.cooldown_minutes))
                trait.cooldownMinutes = Math.max(0, command.cooldown_minutes);

            if (typeof command.item === "string" && command.item.length > 0) {
                // Either a catalogue id, or an emoji nobody has used yet — in
                // which case it joins the catalogue the same way the window's
                // "+ emoji" button adds one.
                const known = PetTraits.dropItems.find(d => d.id === command.item);
                if (known) {
                    trait.item = known.id;
                    trait.gift = known.gift;
                } else {
                    const made = PetTraits.addDropItem(command.item, command.item_label || "",
                                                       command.kind === "malus" ? "malus" : "bonus");
                    if (made === "")
                        return root.fail("item is neither a catalogue id nor a usable emoji: " + command.item);
                    trait.item = made;
                    trait.gift = PetTraits.dropItemById(made).gift;
                }
            }

            // The gift is merged onto whatever the object carries, so naming
            // one stat does not silently zero the other three.
            if (command.gift && typeof command.gift === "object") {
                const base = PetTraits.giftOf(trait);
                const gift = {
                    hunger: base.hunger,
                    energy: base.energy,
                    happiness: base.happiness,
                    hygiene: base.hygiene
                };
                for (const key of ["hunger", "energy", "happiness", "hygiene"]) {
                    const v = command.gift[key];
                    if (typeof v === "number" && isFinite(v))
                        gift[key] = Math.max(-100, Math.min(100, v));
                }
                trait.gift = gift;
            }
        }

        PetTraits.upsert(trait);

        const live = PetTraits.list.find(t => t.id === trait.id) ?? null;
        return JSON.stringify({
            ok: true,
            action: "set",
            id: trait.id,
            trait: live === null ? trait : {
                id: live.id,
                label: live.label,
                source: live.source,
                role: live.role,
                value: live.value,
                unit: live.unit,
                drop: live.drop === null ? null : {
                    when: live.drop.when,
                    every: live.drop.every,
                    threshold: live.drop.threshold,
                    step: live.drop.step,
                    item: live.drop.item.id,
                    glyph: live.drop.item.glyph,
                    kind: live.drop.item.kind,
                    gift: live.drop.gift
                }
            },
            note: "Saved to ~/.config/quickshell/pet-traits.json; the running panel picked it up already."
        });
    }

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
