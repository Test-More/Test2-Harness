function build_resource(cont, item) {
    var res = $('<div class="resource"></div>');
    var name = $('<h1>' + item.resource + '</h1>');
    res.append(name);

    if (item.groups) {
        item.groups.forEach(function(group) {
            build_group(res, group);
        });
    }

    return res;
}

function build_group(res, group) {
    if (group.title) { res.append('<h2>' + group.title + '</h2>') }

    group.tables.forEach(function(table) {
        build_table(res, table);
    });
}

function build_table(res, table) {
    if (table.title) { res.append('<h3>' + table.title + '</h3>') }

    var t = $('<table></table>');

    if (table.header) {
        var h = $('<tr></tr>');

        table.header.forEach(function(label) {
            h.append('<th>' + label + '</th>');
        });

        t.append(h);
    }

    table.rows.forEach(function(row) {
        var tr = $('<tr></tr>');

        row.forEach(function(td) {
            tr.append('<td>' + td + '</td>');
        });

        t.append(tr);
    });

    res.append(t);
}

function select_stamp(stamps) {
    if (!stamps) { return }
    if (!stamps.select) { return }

    var selected = stamps.selected;
    if (!selected) { return }

    var data = stamps.lookup[selected];
    if (data == null) { return }

    var name = data["val"];
    var idx  = data["idx"];

    stamps.selected = null;
    stamps.select.html('<a href="' + res_uri + '/' + selected + '">' + name + '</a>');
    stamps.dom.val(idx);
}

function load_resource(stamp) {
    var content = $('div#content');

    $.ajax(stamp_uri + '/' + stamp, {
        'data': { 'content-type': 'application/json' },
        'error': function() {
            content.append('<div class="error">Could not load resources for timestamp "' + stamp + '"</div>');
        },
        'success': function(item) {
            var resources = [];

            console.log(stamp, item);
            item.resources.forEach(function(res) {
                var res = build_resource( content, res );
                resources.push(res);
            });

            content.children('div.resource').detach();
            content.append(resources);

            history.replaceState({"stamp": stamp}, null, res_uri + '/' + stamp);
        },
    });
}

$(function() {
    var content = $('div#content');
    var runs    = $('div#run_list');

    var stamps = {
        "dom": null,
        "list": [],
        "lookup": {},
        "selected": null,
        "select": null,
    };

    var complete = false;
    t2hui.fetch(
        stamp_uri,
        {
            "done": function() {
                if (complete) { return }
                content.prepend('<div class="timeout">Connection has timed out, reload page or click "tail" to get updates.</div>');
            }
        },
        function(item) {
            if (!item)         { return }
            if (item.complete) { complete = true }

            if (item.run_id) {
                var stream_url = base_uri + 'stream/run/' + item.run_id;
                var run_table = t2hui.runtable.build_table();
                runs.append(run_table.render());

                t2hui.fetch(
                    stream_url,
                    {},
                    function(item) {
                        if (item.type === 'run') {
                            run_table.render_item(item.data, item.data.run_id);
                        }
                    }
                );
            }

            if (item.stamps) {
                if (!stamps.dom) {
                    stamps.dom = $('<input type="range" min="0"></input>');
                    stamps.tail = $('<input type="button" value="&#9658;"></input>');
                    stamps.stop = $('<input type="button" value="&#9632;"></input>');
                    stamps.prev = $('<input type="button" value="&lt;"></input>');
                    stamps.next = $('<input type="button" value="&gt;"></input>');
                    stamps.first = $('<input type="button" value="&lt;&lt;"></input>');
                    stamps.last = $('<input type="button" value="&gt;&gt;"></input>');
                    var stamp_inner = $('<div class="stamp_selector_inner"></div>');
                    var stamp_wrap = $('<div class="stamp_selector"><h1>Timestamp Selector</h1></div>');

                    stamps.select = $('<div class="stamp_selector_select"></div>');

                    stamp_inner.append(stamps.dom);
                    stamp_wrap.append(stamps.last, stamps.next, stamps.tail, stamps.stop, stamps.prev, stamps.first, stamp_inner, stamps.select);
                    content.find('#put_stamps_here').append(stamp_wrap);

                    var selector_change = function() {
                        tailing = false;
                        var idx = stamps.dom.val();
                        load_resource(stamps.list[idx]);
                        stamps.selected = stamps.list[idx];
                        select_stamp(stamps);
                    };

                    var pick_stamp = function(stamp) {
                        load_resource(stamp);
                        stamps.selected = stamp;
                        select_stamp(stamps);
                    }

                    stamps.dom.on('input', selector_change);
                    stamps.dom.change(selector_change);

                    stamps.stop.click(function()  { tailing = false });
                    stamps.tail.click(function()  { tailing = true;  pick_stamp(stamps.list[stamps.list.length - 1]) });
                    stamps.first.click(function() { tailing = false; pick_stamp(stamps.list[0]); });
                    stamps.last.click(function()  { tailing = false; pick_stamp(stamps.list[stamps.list.length - 1]) });

                    stamps.next.click(function() {
                        var idx = stamps.dom.val();
                        idx = idx - (0 - 1);
                        if (!stamps.list[idx]) { return }
                        tailing = false;
                        pick_stamp(stamps.list[idx]);
                    });

                    stamps.prev.click(function() {
                        var idx = stamps.dom.val();
                        idx = idx - 1;
                        if (idx < 0) { return }
                        if (!stamps.list[idx]) { return }
                        tailing = false;
                        pick_stamp(stamps.list[idx]);
                    });

                    if (selected) {
                        pick_stamp(selected);
                    }
                }

                item.stamps.forEach(function(stamp) {
                    var id = stamp[0];
                    var val = stamp[1];

                    if (stamps.lookup[id]) { return }

                    stamps.list.push(id);
                    var idx = stamps.list.length - 1
                    stamps.lookup[id] = {
                        "idx": idx,
                        "val": val,
                    };

                    stamps.dom.attr("max", idx);

                    if (tailing) {
                        stamps.selected = id;
                        load_resource(id);
                    }
                });

                if (stamps.selected && stamps.select) { select_stamp(stamps) }
            }
        },
    );
});
