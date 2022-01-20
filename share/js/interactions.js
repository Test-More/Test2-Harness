function build_interactions(item, state) {
    var content = $('div#content');

    if (item.type === 'run') {
        var run_table = t2hui.runtable.build_table();
        content.append(run_table.render());
        run_table.render_item(item.data, item.data.run_id);
        return;
    }

    else if (item.type === 'count') {
        content.append('<hr />');

        content.append('<h2>Found ' + item.data + ' jobs that overlapped with this event</h2>');
        content.append("<p>Click any file in this list to jump down to it's event data. Only events within " + context_count + " seconds of this failure will be shown.</p>");

        var form = $('<form><input id="context_count" value="' + context_count + '" /><input type="submit" id="context_count_go" value="reload" /></input></form>');
        content.append(form);
        form.submit(function() {
            var val = $('input#context_count').val();
            if (!val) { return true };
            context_count = val;

            content.empty();

            state = {};
            var uri = base_uri + 'interactions/data/' + event_id + '/' + val;
            t2hui.fetch(uri, {}, function(item) { build_interactions(item, state) });
            return true;
        });

        var list = $('<ol></ol>');
        content.append(list);
        state.list = list;
    }

    else if (item.type === 'job') {
        state.event_table = null;
        content.append('<hr id="section_' + item.data.job_key + '" />');

        var job_table = t2hui.jobtable.build_table(null);

        if (state.list) {
            state.list.append('<li><a href="#section_' + item.data.job_key + '">' + item.data.file + '</a></li>');
        }

        content.append(job_table.render());
        job_table.render_item(item.data, item.data.job_key);
        return;
    }

    if (item.type === 'event') {
        if (!state.event_table) {
            var event_controls = t2hui.eventtable.build_controls(null, null);
            var event_table   = t2hui.eventtable.build_table(null, null, event_controls);

            content.append(event_controls.dom);
            content.append(event_table.render());

            state.event_controls = event_controls;
            state.event_table    = event_table;
        }

        state.event_table.render_item(item.data, item.data.event_id);
    }
}

$(function() {
    var content = $('div#content').empty();
    var state = {};
    t2hui.fetch(data_uri, {}, function(item) { build_interactions(item, state) });
});
