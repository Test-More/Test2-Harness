$(function() {
    var users     = $('div#run_list');
    var projectss = $('div#run_list');
    var runs      = $('div#run_list');
    var jobs      = $('div#job_list');
    var events    = $('div#event_list');

    var state = {};

    t2hui.fetch(
        data_uri,
        {done: function() {
            if (state.run_table) {
                state.run_table.make_sortable();
            }

            if (state.job_table) {
                state.job_table.make_sortable();
            }
        }},
        function(item) {
            if (item.type === 'event') {
                if (!state.event_table) {
                    var event_controls = t2hui.eventtable.build_controls(null, null);
                    var event_table   = t2hui.eventtable.build_table(null, null, event_controls);

                    //events.append(event_controls.dom);
                    events.append('<h3>Events matching the UUID</h3>');
                    events.append(event_table.render());

                    state.event_controls = event_controls;
                    state.event_table    = event_table;
                }

                state.event_table.render_item(item.data, item.data.event_id);
            }
            else if (item.type === 'job') {
                if (!state.job_table) {
                    var job_table = t2hui.jobtable.build_table(null);
                    jobs.append('<h3>Jobs matching the UUID, or which have events matching the UUID</h3>');
                    jobs.append(job_table.render());
                    state.job_table = job_table;
                }
                state.job_table.render_item(item.data, item.data.job_key);
            }
            else if (item.type === 'run') {
                if (!state.run_table) {
                    var run_table = t2hui.runtable.build_table();
                    runs.append('<h3>Runs matching the UUID, or which have jobs/events matching the UUID</h3>');
                    runs.append(run_table.render());
                    state.run_table = run_table;
                }
                state.run_table.render_item(item.data, item.data.run_id);
            }
        }
    );

});
