t2hui.project_stats = {};

$(function() {
    t2hui.project_stats.reload(0);
    $('button#update_stats').click(function() { t2hui.project_stats.reload(1) });

    $('div#project div.stats_set > h2').click(function() {
        var h2 = $(this);
        h2.parent().toggleClass('active');
        t2hui.project_stats.reload(0);
    });

    $('input.date_picker').datepicker();

    $('input[name="run_selector"]').change(function() {
        if ($(this).val() === 'limited') {
            $('li#run_selector').show();
        }
        else {
            $('li#run_selector').hide();
        }

        if ($(this).val() === 'date') {
            $('li#date_selector').show();
        }
        else {
            $('li#date_selector').hide();
        }
    });

    $('input[name="user_selector"]').change(function() {
        if ($(this).val() === 'select') {
            $('li#user_selector').show();
        }
        else {
            $('li#user_selector').hide();
        }
    });

});

var id = 1;
t2hui.project_stats.reload = function(all) {
    var n = 0;
    var start;
    var end;

    var run_sel = $('input[name="run_selector"]:checked').val();
    if (run_sel === 'limited') {
        n = $('input#n').val();
    }
    else if (run_sel === 'date') {
        start = $('input#start_date').val();
        end = $('input#end_date').val();
    }

    var p = $('input#project').val();

    var user_sel = $('input[name="user_selector"]:checked').val();

    var users = [];
    if (user_sel === 'owner') {
        users = [$('select#users option').first().val()];
    }
    else if (user_sel === 'other') {
        var first = 0;
        $('select#users option').each(function() {
            if (!first) {
                first = 1;
                return;
            }

            users.push($(this).val());
        });
    }
    else if (user_sel === 'select') {
        users = $('select#users').val();
    }

    // Disabling for now
    var count = 100000;

    $('span.n').text(n);

    var request = [];

    $("div.stat").each(function() {
        var it = $(this);

        if (it.hasClass('loaded') && !all) {
            return;
        }

        var it_type = it.attr('data-stat-type');
        var it_n    = it.attr('data-stat-n');
        var it_id   = it.attr('id');

        if (!it_id) {
            it_id = "gen_id_" + id++;
            it.attr('id', it_id);
        }

        if (!it_n) it_n = n;

        if (it.parent().parent().hasClass('active')) {
            request.push({"id": it_id, "type": it_type, "n": it_n, "users": users, start_date: start, end_date: end});
            it.text('Loading...');
            it.addClass('running');
        }
        else {
            it.empty();
            it.removeClass('unloaded');
        }
    });

    if (request.length < 1) return;

    t2hui.fetch(
        "/project/" + p + '/stats',
        {
            data: JSON.stringify(request),
            dataType: 'json',
            type: 'POST',
            done: function() {},
        },
        function(item) {
            if (!item) return;

            var div =  $('div#' + item.id);
            div.removeClass('running');
            div.removeClass('error_set');
            div.removeClass('success_set');
            div.addClass('loaded');

            if (item.error) {
                var pre = $('<pre></pre>');
                pre.text(item.error);
                div.html(pre);
                div.addClass('error_set');
                return;
            }

            if (item.text) {
                div.text(item.text);
                div.addClass('success_set');
                return;
            }

            if (item.chart) {
                if (item.chart.options.scales.y.ticks.callback === 'percent') {
                    item.chart.options.scales.y.ticks.callback = function(v) { return v + '%' };
                }

                var canvas = $('<canvas></canvas>');
                div.addClass('chart');
                div.html(canvas);
                new Chart(canvas, item.chart);
            }

            if (item.json) {
                var formatter = new JSONFormatter(item.json);
                div.html(formatter.render());
                var download = $('<a class="download">Download</a>');

                download.attr("href", "data:text/json;charset=utf-8," + encodeURIComponent(JSON.stringify(item.json)));
                download.attr("download", "uncovered.json");

                div.prepend(download);
            }

            var build_pair_table = function(pairs) {
                var table = $('<table class="pairs"></table>');
                pairs.forEach(function(row) {
                    var html_row = $('<tr></tr>');
                    var header = $('<th>' + row[0] + '</th>');
                    html_row.append(header);
                    if (row.length === 1) {
                        header.attr('colspan', 2);
                        header.addClass('title');
                    }
                    else {
                        header.append(':');
                        var value  = $('<td>' + row[1] + '</td>');
                        html_row.append(value);
                    }
                    table.append(html_row);
                });
                return table;
            }

            if (item.runs) {
                var run_table = t2hui.runtable.build_table();
                div.html(run_table.render());
                item.runs.forEach(function(run) {
                    run_table.render_item(run, run.run_id);
                })
            }

            if (item.pair_sets) {
                div.empty();
                item.pair_sets.forEach(function(pairs) {
                    var table = build_pair_table(pairs);
                    div.append(table);
                });
            }

            if (item.pairs) {
                var table = build_pair_table(item.pairs);
                div.html(table);
            }

            if (item.table) {
                var table = $('<table></table>');
                div.html(table);

                if (item.table.class) table.addClass(item.table.class);

                if (item.table.header) {
                    var header = $('<thead></thead>');
                    table.append(header);
                    var tr = $('<tr></tr>');
                    header.append(tr);

                    item.table.header.forEach(function(head) {
                        var col = $('<th>' + head + '</th>');
                        tr.append(col);
                    });
                }

                var set_id = 1;
                var item_c = 0;
                var showing_set = 1;
                var tbody = $('<tbody></tbody>');
                table.append(tbody);
                item.table.rows.forEach(function(row) {
                    item_c++;
                    if (item_c > count) {
                        item_c = 0;
                        if (showing_set == set_id) {
                            var show_more = $('<span class="show show_more">Show More</span>');
                            var show_all  = $('<span class="show show_all">Show All</span>');
                            table.before(show_all, show_more);

                            show_all.click(function() {
                                show_more.detach();
                                show_all.detach();

                                table.find('tr').show();
                            });

                            show_more.click(function() {
                                showing_set++;
                                table.find('tr.set_id_' + showing_set).show();

                                if (showing_set == set_id) {
                                    show_more.detach();
                                    show_all.detach();
                                }
                            });
                        }
                        set_id++;
                    }

                    var meta = row.shift();
                    var tr = $('<tr class="set_id_' + set_id + '"></tr>');
                    if (set_id > showing_set) tr.hide();

                    tbody.append(tr);
                    if (meta.class) tr.addClass(meta.class);
                    row.forEach(function(col) {
                        var td = $('<td></td>');
                        tr.append(td);

                        if (Array.isArray(col)) {
                            var ul = $('<ul></ul>');
                            td.append(ul);

                            col.forEach(function(item) {
                                var li = $('<li>' + item + '</li>');
                                ul.append(li);
                            });
                        }
                        if (typeof col === "object") {
                            td.text(col.formatted);
                            td.attr('data-order', col.raw);
                        }
                        else {
                            td.text(col);
                        }
                    });
                });

                if (item.table.sortable) {
                    table.before('<small><B>Note:</B> Click on a column title to sort by that column</small><br />');
                    table.DataTable({
                        paging: false,
                        searching: false,
                        info: false,
                        orderCellsTop: true,
                        aaSorting: []
                    });
                }
            }
        }
    );
};
