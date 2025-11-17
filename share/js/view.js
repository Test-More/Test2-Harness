$(function() {
    var runs   = $('div#run_list');
    var jobs   = $('div#job_list');
    var events = $('div#event_list');

    var state = {};

    var fetch_uri = stream_uri;

    var fetch = function() {
        t2hui.fetch(
            fetch_uri,
            {done: function() {
                if (state.run_table) {
                    state.run_table.make_sortable();
                }

                if (state.job_table && state.has_non_harness_job) {
                    state.job_table.make_sortable();
                }
            }},
            function(item) {
                if (item.type === 'event') {
                    item.data.run_uuid  = state.run.run_uuid;
                    item.data.job_uuid = state.job.job_uuid;
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

                    state.event_table.render_item(item.data, item.data.event_uuid);
                }
                else if (item.type === 'job') {
                    item.data.run_uuid = state.run.run_uuid;
                    state.job = item.data;

                    if (!state.job.is_harness_out) {
                        state.has_non_harness_job = 1;
                    }

                    if (!state.job_table) {
                        var job_table = t2hui.jobtable.build_table(state.run);
                        jobs.append(job_table.render());
                        state.job_table = job_table;
                    }
                    state.job_table.render_item(item.data, item.data.job_try_id);
                }
                else if (item.type === 'run') {
                    state.run = item.data;
                    if (!state.run_table) {
                        var run_table = t2hui.runtable.build_table();
                        runs.append(run_table.render());
                        state.run_table = run_table;
                    }
                    state.run_table.render_item(item.data, item.data.run_uuid);
                }
            }
        );
    };

    if (page_num) {
        fetch_uri = stream_uri + '/page/' + page_num;

        var page_elem = $('#run_pager_page');

        $('#run_pager_prev').click(function() {
            if (page_num == 1) { return }
            page_num = page_num - 1;
            page_elem.text("Page: " + page_num);

            $('#runs').remove();
            state.run_table = null;
            fetch_uri = stream_uri + '/page/' + page_num;
            fetch();
        });

        $('#run_pager_next').click(function() {
            page_num = page_num + 1;
            page_elem.text("Page: " + page_num);

            $('#runs').remove();
            state.run_table = null;
            fetch_uri = stream_uri + '/page/' + page_num;
            fetch();
        });
    }
    else {
        $('#run_pager').hide();
    }

    fetch();
});
