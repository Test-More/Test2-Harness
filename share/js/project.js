t2hui.project_stats = {};

$(function() {
    t2hui.project_stats.reload(0);
    $('button#update_stats').click(function() { t2hui.project_stats.reload(1) });

    $('div#project div.stats_set > h2').click(function() {
        var h2 = $(this);
        h2.parent().toggleClass('active');
        t2hui.project_stats.reload(0);
    });
});

var id = 1;
t2hui.project_stats.reload = function(all) {
    var n = $('input#n').val();
    var p = $('input#project').val();

    var count = 10;

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
            request.push({"id": it_id, "type": it_type, "n": it_n});
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
            div.addClass('loaded');

            if (item.error) {
                div.text(item.error);
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

            if (item.table) {
                var table = $('<table></table>');
                div.html(table);

                if (item.table.class) table.addClass(item.table.class);

                if (item.table.header) {
                    var header = $('<tr></tr>');
                    table.append(header);

                    item.table.header.forEach(function(head) {
                        var col = $('<th>' + head + '</th>');
                        header.append(col);
                    });
                }

                var set_id = 1;
                var item_c = 0;
                var showing_set = 1;
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

                    table.append(tr);
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
                        else {
                            td.text(col);
                        }
                    });
                });
            }
        }
    );
};
