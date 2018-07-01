#ifndef DTWCLUST_KAHANSUMMER_HPP_
#define DTWCLUST_KAHANSUMMER_HPP_

#include <vector>

namespace dtwclust {

// for kahan sum (compensated sum)
class KahanSummer
{
public:
    KahanSummer(double * const x, const int nrows, const int ncols = 1);
    void reset();
    void add(const double value, const int i, const int j = 0);

private:
    double* const x_;
    int nrows_;
    std::vector<double> c_, y_, t_;
};

} // namespace dtwclust

#endif // DTWCLUST_KAHANSUMMER_HPP_
