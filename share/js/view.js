$(function() {
    var runs   = $('div#run_list');
    var jobs   = $('div#job_list');
    var events = $('div#event_list');

    var state = {};

    t2hui.fetch(
        stream_uri,
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
                item.data.run_id  = state.run.run_id;
                item.data.job_key = state.job.job_key;
                state.event = item.data;
                if (!state.event_table) {
                    var event_controls = t2hui.eventtable.build_controls(state.run, state.job);
                    var event_table   = t2hui.eventtable.build_table(state.run, state.job, event_controls);

                    events.append(event_controls.dom);
                    events.append(event_table.render());

                    state.event_controls = event_controls;
                    state.event_table    = event_table;

                    if (state.job.status == 'running' || state.job.status == 'pending') {
                        events.addClass('live');
                    }
                }

                state.event_table.render_item(item.data, item.data.event_id);
            }
            else if (item.type === 'job') {
                item.data.run_id = state.run.run_id;
                state.job = item.data;
                if (!state.job_table) {
                    var job_table = t2hui.jobtable.build_table(state.run);
                    jobs.append(job_table.render());
                    state.job_table = job_table;
                }
                state.job_table.render_item(item.data, item.data.job_key);
            }
            else if (item.type === 'run') {
                state.run = item.data;
                if (!state.run_table) {
                    var run_table = t2hui.runtable.build_table();
                    runs.append(run_table.render());
                    state.run_table = run_table;
                }
                state.run_table.render_item(item.data, item.data.run_id);
            }
        }
    );

});
