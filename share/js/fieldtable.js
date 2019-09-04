// var table = field_table(
//  class => TableClass,
//  id => ID (for wrapper)
//
//  fetch => URL_FOR_ITEMS,
//
//  place_row => function(row_html, item, table) { return bool } // true means function placed row, false means append row
//  modify_row_hook => function(row_html, item) { return null },
//
//  row_redraw_check => function(item) { return bool },
//  row_redraw_fetch => function(item) { return uri },
//  row_redraw_interval => integer,
//
//  dynamic_field_attribute => FIELD_NAME,
//  dynamic_field_fetch     => function(field_data) { return uri },
//  dynamic_field_builder   => function(data) { return data },
//
//  columns => [
//      { field: '', label: '', class: '', builder => function(item, col, field_spec) { ... }},
//      ...
//  ],
//
//  postfix_columns => [
//      ...
//  ],
// )

function FieldTable(spec) {
    var me = this;
    me.spec = spec;
    me.rows = [];
    me.columns = [];
    me.postfix_columns = [];
    me.dynamic_columns = [];
    me.dynamic_column_lookup = {};
    me.redraw = {};
    me.redraw_id = 1;
    me.row_state = {};
    me.hidden_columns = {};

    me.render = function() {
        me.table = $('<table class="field-table ' + spec.class + '"></table>');

        me.header = me.render_header();
        var hwrap = $('<thead></thead>');
        hwrap.append(me.header);
        me.table.append(hwrap);

        me.body = $('<tbody></tbody>');
        me.table.append(me.body);

        me.row_state.body = me.body;
        me.row_state.header = me.header;

        if (me.spec.row_redraw_interval) {
            setInterval(function() {
                Object.keys(me.redraw).forEach(function (redraw_id) {
                    var old = me.redraw[redraw_id];
                    delete me.redraw[redraw_id];

                    var uri = me.spec.row_redraw_fetch(old.item);
                    $.ajax(uri, {
                        'data': { 'content-type': 'application/json' },
                        'error': function(a, b, c) { me.redraw[redraw_id] = old },
                        'success': function(item) {
                            var row = me.render_row(item);
                            row.index = old.index;

                            if (me.spec.modify_row_hook) {
                                me.spec.modify_row_hook(row.html, item);
                            }

                            if (me.spec.row_redraw_check(item)) {
                                me.redraw[row.redraw_id] = row;
                            }

                            me.rows[old.index] = row;
                            old.html.replaceWith(row.html);
                            old.html.remove();
                        },
                    });
                });
            }, me.spec.row_redraw_interval);
        }

        if (typeof(me.spec.fetch) === 'string') {
            t2hui.fetch(me.spec.fetch, {done: me.make_sortable}, me.render_item);
        }
        else if (typeof(me.spec.fetch) === 'object') {
            me.spec.fetch.forEach(me.render_item);
            if (me.spec.fetch.length > 1) {
                me.make_sortable();
            }
        }

        var wrapper = $('<div id="' + spec.id + '" class="field-table-wrapper ' + spec.class + '"></div>');
        wrapper.append(me.table);

        return wrapper;
    }

    me.make_sortable = function() {
        if (!me.spec.sortable) { return }

        me.table.DataTable({
            paging: false,
            searching: false,
            info: false,
            orderCellsTop: true,
        });

//        var them = me.table.children('thead').children('tr').first().children('th');

//        them.click(function() {
//            $(this).addClass('sorting');
//        });
//
//        var x = me.table.tablesort({
//            'compare': function(a, b) {
//                var an = parseFloat(a);
//                var bn = parseFloat(b);
//
//                if (!isNaN(an) && !isNaN(bn)) {
//                    if (an > bn) {
//                        return 1;
//                    } else if (an < bn) {
//                        return -1;
//                    } else {
//                        return 0;
//                    }
//                }
//                if (!isNaN(an)) {
//                    return 1;
//                }
//                if (!isNaN(bn)) {
//                    return -1;
//                }
//
//                if (a > b) {
//                    return 1;
//                } else if (a < b) {
//                    return -1;
//                } else {
//                    return 0;
//                }
//            }
//        });
//
//        me.table.on('tablesort:complete', function() {
//            them.removeClass('sorting');
//        })
    }

    me.render_item = function(item) {
        if (me.spec.expand_item) {
            var list = me.spec.expand_item(item);
            list.forEach(me._render_item);
        }
        else {
            me._render_item(item);
        }
    }

    me._render_item = function(item) {
        var row = me.render_row(item);

        if (me.spec.modify_row_hook) {
            me.spec.modify_row_hook(row.html, item);
        }

        if (me.spec.place_row) {
            if (!me.spec.place_row(row.html, item, me.table, me.row_state)) {
                me.body.append(row.html);
            }
        }
        else {
            me.body.append(row.html);
        }

        if (me.spec.row_redraw_check) {
            if (me.spec.row_redraw_check(item)) {
                row.redraw_id = me.redraw_id++;
                me.redraw[row.redraw_id] = row;
            }
        }

        row.index = me.rows.length;
        me.rows.push(row);
    }

    me.render_row = function(item) {
        var row = {
            'html': $('<tr></tr>'),
            'columns': [],
            'dynamic_columns': [],
            'postfix_columns': [],
            'item': item,
        };

        row.html.hover(
            function() { row.html.addClass('hover') },
            function() { row.html.removeClass('hover') },
        );

        if (me.spec.columns) {
            me.spec.columns.forEach(function(data) {
                var col = me.render_row_col(data, item);
                row.html.append(col);
                row.columns.push(col);
            });
        }

        me.dynamic_columns.forEach(function(header) {
            var name = header.attr('data-dynamic-name');
            var col = $('<td class="col-' + name + '"></td>');
            row.html.append(col);
            row.dynamic_columns.push(col);
            if (me.hidden_columns[name]) {
                col.hide();
            }
        });

        if (me.spec.postfix_columns) {
            me.spec.postfix_columns.forEach(function(data) {
                var col = me.render_row_col(data, item);
                row.html.append(col);
                row.postfix_columns.push(col);
            });
        }

        var attr = me.spec.dynamic_field_attribute;
        if (attr && item[attr]) {
            item[attr].forEach(function(field) {
                var col = me.render_dynamic_col(field, field.name);
                if (me.hidden_columns[field.name]) {
                    col.hide();
                }

                var idx = me.find_dynamic_column(field.name);
                if (idx === null) {
                    idx = me.inject_dynamic_column({"name": field.name});
                    if (row.dynamic_columns.length) {
                        row.dynamic_columns[row.dynamic_columns.length - 1].after(col);
                    }
                    else if (row.columns.length) {
                        row.columns[row.columns.length - 1].after(col);
                    }
                    else {
                        row.prepend(col);
                    }

                    row.dynamic_columns.push(col);
                }
                else {
                    row.dynamic_columns[idx].replaceWith(col);
                    row.dynamic_columns[idx] = col;
                }
            })
        }

        return row;
    }

    me.render_dynamic_col = function(field, name) {
        var tooltable = $('<table class="tool_table"></table>');
        var toolrow = $('<tr></tr>');
        tooltable.append(toolrow);

        var col = $('<td class="col-' + name + '"></td>');
        col.append(tooltable);

        toolrow.append('<td>' + field.details + '</td>');

        if (field.raw) {
            col.attr('data-order', field.raw);
            var tt = t2hui.build_tooltip(col.parent(), field.raw);
            var td = $('<td></td>');
            td.append(tt);
            toolrow.prepend(td);
        }

        if (field.data) {
            var viewer = $('<div class="tool etoggle" title="Extended Data"><img src="/img/data.png" /></div>');
            var td = $('<td></td>');
            td.append(viewer);
            toolrow.prepend(td);
            viewer.click(function() {
                $('#modal_body').empty();
                $('#modal_body').text("loading...");
                $('#free_modal').slideDown();

                var uri = me.spec.dynamic_field_fetch(field);

                $.ajax(uri, {
                    'data': { 'content-type': 'application/json' },
                    'success': function(field) {
                        var data = me.spec.dynamic_field_builder ? me.spec.dynamic_field_builder(field, name) : field;
                        $('#modal_body').empty();
                        $('#modal_body').jsonView(data, {collapsed: true});
                    },
                });
            });
        }

        if (field.link) {
            var link = $('<td><a class="tool etoggle" title="Link" href="' + field.link + '"><img src="/img/link.png" /></a></td>');
            toolrow.prepend(link);
        }

        return col;
    }

    me.render_row_col = function(data, item) {
        var col = $('<td class="' + data.class + '"></td>');

        if (data.builder) {
            data.builder(item, col, data);
        }
        else {
            col.text(item[data.name]);
        }

        return col;
    }

    me.render_header = function() {
        var header = $('<tr class="field-table-header"></tr>');

        if (me.spec.columns) {
            me.spec.columns.forEach(function(data) {
                var col = me.render_header_col(data);
                header.append(col);
                me.columns.push(col);
            });
        }

        if (me.spec.postfix_columns) {
            me.spec.postfix_columns.forEach(function(data) {
                var col = me.render_header_col(data);
                header.append(col);
                me.postfix_columns.push(col);
            });
        }

        return header;
    }

    me.column_class = function(data) {
        return "col-" + (data.class || data.name);
    }

    me.render_header_col = function(data) {
        var label = data.label ? data.label : data.name;
        var inner = $('<div class="field-table-header-col-inner">' + label + '</div>');
        var col = $('<th class="field-table-header-col ' + me.column_class(data) + '"></th>');
        col.append(inner);
        inner.click(function() { col.trigger('click'); });
        return col;
    }

    me.find_dynamic_column = function(field) {
        if (me.dynamic_column_lookup[field] !== null && me.dynamic_column_lookup[field] !== undefined) {
            return me.dynamic_column_lookup[field];
        }

        return null;
    }

    me.inject_dynamic_column = function(data) {
        var col = me.render_header_col(data);
        col.addClass('dynamic');
        col.attr('data-dynamic-name', data.name);

        var cclass = me.column_class(data);

        var tools = col.children('div').first();

        var close_icon = $('<img src="/img/close.png" />');
        var close = $('<div class="etoggle" title="hide column"></div>');
        close.append(close_icon);

        close.hover(
            function() { close_icon.attr('src', '/img/close_red.png') },
            function() { close_icon.attr('src', '/img/close.png') },
        );

        close.click(function() {
            col.hide();
            me.table.find('td.' + cclass).hide();
            me.hidden_columns[data.name] = 1;
            return false;
        });
        tools.append(close);

        if (me.dynamic_columns.length) {
            me.dynamic_columns[me.dynamic_columns.length - 1].after(col);

            me.rows.forEach(function(row) {
                var td = $('<td class="' + cclass + '"></td>');
                row.dynamic_columns[row.dynamic_columns.length - 1].after(td);
                row.dynamic_columns.push(td);
            });
        }
        else if (me.columns.length) {
            me.columns[me.columns.length - 1].after(col);

            me.rows.forEach(function(row) {
                var td = $('<td class="' + cclass + '"></td>');
                row.columns[row.columns.length - 1].after(td);
                row.dynamic_columns.push(td);
            });
        }
        else {
            me.header.prepend(col);

            var row;
            me.rows.forEach(function(row) {
                var td = $('<td class="' + cclass + '"></td>');
                row.append(td);
                row.dynamic_columns.push(td);
            });
        }

        me.dynamic_column_lookup[data.name] = me.dynamic_columns.length;
        me.dynamic_columns.push(col);

        return me.dynamic_column_lookup[data.name];
    }

    return me;
}
