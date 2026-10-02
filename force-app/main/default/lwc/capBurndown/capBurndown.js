import { LightningElement } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getAllActivityCaps from '@salesforce/apex/EngagementBurnController.getAllActivityCaps';

const COLUMNS = [
    { label: 'Account', fieldName: 'accountName', wrapText: true, sortable: true },
    { label: 'Engagement', fieldName: 'engagementName', wrapText: true, sortable: true,
      cellAttributes: { class: { fieldName: 'statusClass' } } },
    { label: 'Element', fieldName: 'elementName', wrapText: true, sortable: true },
    { label: 'Cap', fieldName: 'cap', type: 'currency', sortable: true,
      typeAttributes: { currencyCode: 'USD', maximumFractionDigits: 0 }, cellAttributes: { alignment: 'right' } },
    { label: 'Consumed', fieldName: 'consumed', type: 'currency', sortable: true,
      typeAttributes: { currencyCode: 'USD', maximumFractionDigits: 0 }, cellAttributes: { alignment: 'right' } },
    { label: '% of cap cons.', fieldName: 'consumedPct', type: 'number', sortable: true,
      typeAttributes: { maximumFractionDigits: 1 }, cellAttributes: { alignment: 'right' } },
    { label: 'Forecast', fieldName: 'forecast', type: 'currency', sortable: true,
      typeAttributes: { currencyCode: 'USD', maximumFractionDigits: 0 }, cellAttributes: { alignment: 'right' } },
    { label: '% of cap fcst.', fieldName: 'forecastPct', type: 'number', sortable: true,
      typeAttributes: { maximumFractionDigits: 1 }, cellAttributes: { alignment: 'right' } },
    { label: 'Projected overage', fieldName: 'overage', type: 'currency', sortable: true,
      typeAttributes: { currencyCode: 'USD', maximumFractionDigits: 0 }, cellAttributes: { alignment: 'right' } },
    { label: 'Status', fieldName: 'status', sortable: true, cellAttributes: { class: { fieldName: 'statusClass' } } },
    { type: 'button-icon', fixedWidth: 40,
      typeAttributes: { iconName: 'utility:new_window', title: 'Open engagement in new tab', name: 'open', variant: 'bare' } }
];

const PAGE_SIZE = 20;

export default class CapBurndown extends NavigationMixin(LightningElement) {
    columns = COLUMNS;
    allRows = [];        // full, globally sorted result set
    chartData = [];      // % of cap used, one bar per capped activity (full filtered set)
    error;
    loading = false;

    pageNumber = 1;
    pageSize = PAGE_SIZE;

    managerUserId = null;
    accountId = null;

    // Default global sort: highest projected % of cap first
    sortedBy = 'forecastPct';
    sortDirection = 'desc';

    connectedCallback() {
        this.load();
    }

    load() {
        this.loading = true;
        getAllActivityCaps({ managerUserId: this.managerUserId, accountId: this.accountId })
            .then((data) => {
                const mapped = (data || []).map((c) => ({
                    ...c,
                    statusClass: this.statusClass(c.status)
                }));
                this.allRows = sortData(mapped, this.sortedBy, this.sortDirection);
                this.chartData = buildChart(mapped);
                this.pageNumber = 1;
                this.error = undefined;
            })
            .catch((err) => {
                this.error = err;
                this.allRows = [];
                this.chartData = [];
            })
            .finally(() => {
                this.loading = false;
            });
    }

    statusClass(status) {
        switch (status) {
            case 'Over cap': return 'slds-text-color_error';
            case 'At risk':  return 'slds-text-color_error';
            case 'On track': return 'slds-text-color_success';
            default:         return 'slds-text-color_warning'; // Watch / Under-running
        }
    }

    handleSort(event) {
        this.sortedBy = event.detail.fieldName;
        this.sortDirection = event.detail.sortDirection;
        this.allRows = sortData(this.allRows, this.sortedBy, this.sortDirection);
        this.pageNumber = 1;
    }

    handleAccountChange(event) {
        this.accountId = event.detail.recordId || null;
        this.load();
    }

    handleManagerChange(event) {
        this.managerUserId = event.detail.recordId || null;
        this.load();
    }

    handleClear() {
        this.accountId = null;
        this.managerUserId = null;
        this.template.querySelectorAll('lightning-record-picker').forEach((p) => p.clearSelection());
        this.load();
    }

    handlePrev() {
        if (this.pageNumber > 1) this.pageNumber -= 1;
    }

    handleNext() {
        if (this.pageNumber < this.totalPages) this.pageNumber += 1;
    }

    handleRowAction(event) {
        const id = event.detail.row.engagementId;
        if (!id) return;
        this[NavigationMixin.GenerateUrl]({
            type: 'standard__recordPage',
            attributes: { recordId: id, objectApiName: 'KimbleOne__DeliveryGroup__c', actionName: 'view' }
        }).then((url) => {
            window.open(url, '_blank');
        });
    }

    get rows() {
        const start = (this.pageNumber - 1) * this.pageSize;
        return this.allRows.slice(start, start + this.pageSize);
    }
    get totalCount() { return this.allRows.length; }
    get totalPages() { return Math.max(1, Math.ceil(this.allRows.length / this.pageSize)); }
    get hasRows() { return this.allRows.length > 0; }
    get hasChart() { return this.chartData && this.chartData.length > 0; }
    get showEmpty() { return !this.loading && !this.error && this.allRows.length === 0; }
    get isFirstPage() { return this.pageNumber <= 1; }
    get isLastPage() { return this.pageNumber >= this.totalPages; }
    get pageLabel() {
        if (!this.totalCount) return 'No capped activities';
        return `Page ${this.pageNumber} of ${this.totalPages} · ${this.totalCount} capped activities`;
    }
}

/** Stable client-side sort; nulls always sort last regardless of direction. */
function sortData(rows, field, direction) {
    const factor = direction === 'asc' ? 1 : -1;
    const cloned = [...rows];
    cloned.sort((a, b) => {
        let x = a[field];
        let y = b[field];
        if (x == null && y == null) return 0;
        if (x == null) return 1;
        if (y == null) return -1;
        if (typeof x === 'string') { x = x.toLowerCase(); y = String(y).toLowerCase(); }
        if (x > y) return factor;
        if (x < y) return -factor;
        return 0;
    });
    return cloned;
}

/**
 * Horizontal bar per capped activity showing % of cap used (consumed / cap), color-coded:
 * green <= 50%, yellow 50-80%, red > 80%. Sorted highest-first; spans the full filtered set.
 */
function buildChart(rows) {
    const bars = rows.map((r) => {
        const pct = r.consumedPct == null ? 0 : r.consumedPct;
        const clamped = Math.max(0, Math.min(pct, 100));
        let cls = 'bar-fill bar-green';
        if (pct > 80) cls = 'bar-fill bar-red';
        else if (pct > 50) cls = 'bar-fill bar-yellow';
        const label = r.engagementName || r.elementName || r.activityName;
        const title = [r.accountName, r.engagementName, r.elementName].filter(Boolean).join(' · ');
        return {
            key: r.activityId,
            label,
            title,
            pct,
            valueLabel: `${pct}%`,
            widthStyle: `width:${clamped}%;`,
            barClass: cls
        };
    });
    bars.sort((a, b) => b.pct - a.pct);
    return bars;
}
